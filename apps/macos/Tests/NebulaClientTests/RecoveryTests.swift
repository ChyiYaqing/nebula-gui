import Foundation
import XCTest
@testable import NebulaClient

final class RecoveryTests: XCTestCase {
    func testUserIntentInvalidatesLateRecovery() throws {
        var state = SessionRecovery(); let now = Date(timeIntervalSince1970: 100)
        XCTAssertNil(state.schedule(code: "backend_stopped", at: now))
        state.userConnect("first")
        _ = state.schedule(code: "cleanup_incomplete", at: now)
        let old = try XCTUnwrap(state.beginAttempt(at: now.addingTimeInterval(1)))
        state.userDisconnect()
        XCTAssertFalse(state.accepts(old))
        XCTAssertNil(state.schedule(code: "backend_stopped", at: now))
        state.userConnect("second")
        XCTAssertFalse(state.accepts(old))
        XCTAssertEqual(state.desiredProfileID, "second")
    }
    func testCrashLoopHasFiniteBudgetUntilStable() throws {
        var state = SessionRecovery(); var now = Date(timeIntervalSince1970: 100)
        state.userConnect("network")
        for number in 1...5 {
            now = try XCTUnwrap(state.schedule(code: "backend_stopped", at: now))
            XCTAssertEqual(state.beginAttempt(at: now)?.number, number)
            state.observedStarted(at: now)
            now = now.addingTimeInterval(2)
        }
        XCTAssertNil(state.schedule(code: "backend_stopped", at: now))
        XCTAssertEqual(state.attempts, 5)
        state.observedStarted(at: now)
        state.observedStarted(at: now.addingTimeInterval(60))
        XCTAssertEqual(state.attempts, 0)
    }
    func testSleepOfflineAndInvalidConfigNeverCreateRetry() throws {
        var state = SessionRecovery(); let now = Date()
        state.userConnect("network")
        for code in ["expired", "invalid_config", "helper_upgrade_required", "untrusted_helper"] {
            XCTAssertNil(state.schedule(code: code, at: now))
        }
        state.environment(sleeping: true, networkAvailable: true)
        XCTAssertNil(state.schedule(code: "backend_stopped", at: now))
        state.environment(sleeping: false, networkAvailable: false)
        XCTAssertNil(state.schedule(code: "backend_stopped", at: now))
        state.environment(sleeping: false, networkAvailable: true)
        XCTAssertNotNil(state.schedule(code: "backend_stopped", at: now))
        state.setEnabled(false)
        XCTAssertNil(state.beginAttempt(at: now.addingTimeInterval(10)))
    }
    func testTransportRecoveryRequiresConfirmedDisconnectedStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("backend")
        func install(_ state: String, exit: Int = 0) throws {
            let script = #"""
            #!/bin/sh
            while IFS= read -r line; do
              request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
              case "$line" in
                *'"method":"recover"'*) printf '{"version":1,"id":"%s","result":{"state":"STATE","peers":[]}}\n' "$request_id" ;;
                *) printf '{"version":1,"id":"%s","result":[]}\n' "$request_id" ;;
              esac
            done
            exit EXIT
            """#.replacingOccurrences(of: "STATE", with: state).replacingOccurrences(of: "EXIT", with: String(exit))
            try Data(script.utf8).write(to: helper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        try install("disconnected", exit: 1)
        let client = BackendClient(executable: helper, store: directory.appendingPathComponent("store"))
        _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        do { try await client.shutdown(); XCTFail("Expected cleanup warning") } catch {}
        try install("started")
        do { _ = try await client.recover(); XCTFail("An active state must not clear cleanup uncertainty") } catch {}
        do { _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self); XCTFail("Warning was cleared without proof") } catch {}
        try install("disconnected")
        let recovered = try await client.recover()
        XCTAssertEqual(recovered.state, "disconnected")
        let profiles = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        XCTAssertTrue(profiles.isEmpty)
        try await client.shutdown()
    }
}

extension RecoveryTests {
    func testPermanentShutdownRejectsLateRequestsAndRecovery() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NEBULA_GUI_TEST_BACKEND"] else { throw XCTSkip("Built backend required") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = BackendClient(executable: URL(fileURLWithPath: binary), store: directory)
        _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        try await client.shutdown(permanently: true)
        do {
            _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
            XCTFail("A late refresh restarted the backend")
        } catch { XCTAssertEqual((error as? BackendProblem)?.code, "backend_closed") }
        do { _ = try await client.recover(); XCTFail("Recovery reopened a closed client") }
        catch { XCTAssertEqual((error as? BackendProblem)?.code, "backend_closed") }
        let reopened = BackendClient(executable: URL(fileURLWithPath: binary), store: directory)
        let profiles = try await reopened.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        XCTAssertTrue(profiles.isEmpty)
        try await reopened.shutdown()
    }
}
