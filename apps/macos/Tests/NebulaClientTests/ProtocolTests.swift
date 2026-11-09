import XCTest
@testable import NebulaClient

final class ProtocolTests: XCTestCase {
    func testDecodesKernelLogPage() throws {
        let data = Data(#"{"version":1,"id":"a","result":{"available":true,"entries":[{"seq":7,"time":"2026-11-07T07:00:00.123456789Z","level":"error","message":"Failed to get a tun/tap device","fields":[{"key":"error","value":"denied"},{"key":"udpAddr","value":"198.51.100.1:4242"}],"hidden":2},{"seq":8,"time":"2026-11-07T07:00:01Z","level":"info","message":"ok","fields":[]}]}}"#.utf8)
        let page = try Wire.decode(KernelLogPage.self, from: data, requestID: "a")
        XCTAssertTrue(page.available)
        XCTAssertEqual(page.entries.map(\.id), [7, 8])
        XCTAssertEqual(page.entries[0].detail, "error=denied udpAddr=198.51.100.1:4242")
        XCTAssertEqual(page.entries[0].hidden, 2)
        XCTAssertNil(page.entries[1].hidden)
    }
    func testCorrelatedSuccess() throws {
        let data = Data(#"{"version":1,"id":"a","result":[]}"#.utf8)
        let profiles = try Wire.decode([NetworkProfile].self, from: data, requestID: "a")
        XCTAssertTrue(profiles.isEmpty)
    }
    func testRejectsWrongResponseIDAndVersion() {
        for json in [#"{"version":2,"id":"a","result":[]}"#, #"{"version":1,"id":"wrong","result":[]}"#] {
            XCTAssertThrowsError(try Wire.decode([NetworkProfile].self, from: Data(json.utf8), requestID: "a")) {
                XCTAssertEqual(($0 as? BackendProblem)?.code, "protocol_mismatch")
            }
        }
    }
    func testPreservesStructuredError() {
        let data = Data(#"{"version":1,"id":"a","error":{"code":"missing_file","message":"缺少密钥","field":"pki.key"}}"#.utf8)
        XCTAssertThrowsError(try Wire.decode([NetworkProfile].self, from: data, requestID: "a")) {
            XCTAssertEqual(($0 as? BackendProblem)?.field, "pki.key")
        }
    }
    func testRejectsMissingResultAndMalformedJSON() {
        for json in ["not json", #"{"version":1,"id":"a"}"#] {
            XCTAssertThrowsError(try Wire.decode([NetworkProfile].self, from: Data(json.utf8), requestID: "a"))
        }
    }
    func testRequestUsesNamedFields() throws {
        let request = BackendRequest(method: "preview", path: "/tmp/config.yaml", files: ["key": "/tmp/host.key"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["method"] as? String, "preview")
        XCTAssertNil(json["shell"])
    }
    func testPrivatePipeWithActualBackend() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NEBULA_GUI_TEST_BACKEND"] else {
            throw XCTSkip("Set NEBULA_GUI_TEST_BACKEND to test the built backend")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = BackendClient(executable: URL(fileURLWithPath: binary), store: directory)
        do {
            let profiles = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
            XCTAssertTrue(profiles.isEmpty)
            let status = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
            XCTAssertEqual(status.state, "disconnected")
            XCTAssertFalse(status.isStarted)
            try await client.shutdown()
            // No sleep: shutdown must wait until the store lock has been released.
            let reloaded = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
            XCTAssertTrue(reloaded.isEmpty)
            try await client.shutdown()
            try? FileManager.default.removeItem(at: directory)
        } catch {
            try? await client.shutdown()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func testUnresponsiveChildDoesNotLoseForcedCleanupWarning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("unresponsive-helper")
        // Answers one request only after ignoring TERM, then never again. Without this
        // handshake a slow start let the timeout's TERM end the script before the trap (#79).
        let script = #"""
        #!/bin/sh
        trap '' TERM
        IFS= read -r line
        request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
        printf '{"version":1,"id":"%s","result":[]}\n' "$request_id"
        while IFS= read -r line; do :; done
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        // The timeout also bounds the handshake, so it leaves room for a slow start.
        let client = BackendClient(executable: helper, store: directory.appendingPathComponent("store"), requestTimeout: 3)
        _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        for attempt in 0..<2 {
            do {
                _ = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
                XCTFail("Unresponsive backend must not produce a connection status")
            } catch {
                XCTAssertEqual((error as? BackendProblem)?.code, "cleanup_incomplete", "attempt \(attempt)")
            }
        }
        try await client.shutdown()
    }

    func testShutdownTimeoutAlsoLocksCleanupWarning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("shutdown-helper")
        let script = #"""
        #!/bin/sh
        trap '' TERM
        IFS= read -r line
        request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
        printf '{"version":1,"id":"%s","result":[]}\n' "$request_id"
        exec /bin/sleep 30
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let client = BackendClient(executable: helper, store: directory.appendingPathComponent("store"), requestTimeout: 30)
        _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        do { try await client.shutdown(); XCTFail("Expected incomplete cleanup") }
        catch { XCTAssertEqual((error as? BackendProblem)?.code, "cleanup_incomplete") }
        do {
            _ = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
            XCTFail("A forced shutdown must not silently restart the backend")
        } catch { XCTAssertEqual((error as? BackendProblem)?.code, "cleanup_incomplete") }
        try await client.shutdown()
    }

}
