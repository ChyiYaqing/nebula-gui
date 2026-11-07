import Foundation
import XCTest
@testable import NebulaClient

final class AuthorizationTests: XCTestCase {
    func testAppleScriptReturnsStructuredFailureWithoutRawOutput() throws {
        let plan = AuthorizationPlan(script: "printf sensitive-fixture; echo sensitive-fixture >&2; exit 73")
        let script = plan.appleScript.replacingOccurrences(of: " with administrator privileges", with: "")
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        guard process.terminationStatus == 0 else { return }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(result, ["version": 1, "errorCode": 73])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sensitive-fixture"))
    }
    func testAuthorizationResultDistinguishesConflictAndCancellation() throws {
        XCTAssertNoThrow(try AuthorizationPlan.validateResult(Data(#"{"version":1,"errorCode":0}"#.utf8)))
        for (number, code) in [(73, "legacy_service_running"), (-128, "authorization_cancelled"), (74, "authorization_failed")] {
            XCTAssertThrowsError(try AuthorizationPlan.validateResult(Data("{\"version\":1,\"errorCode\":\(number)}".utf8))) { error in
                XCTAssertEqual((error as? BackendProblem)?.code, code)
                if number == 73 { XCTAssertTrue(error.localizedDescription.contains("旧 Nebula 服务仍在运行")) }
            }
        }
    }
    func testAuthorizationResultRejectsMalformedOrUnexpectedResponses() throws {
        for response in ["sensitive-fixture (-128)", #"{"version":2,"errorCode":73}"#, #"{"version":1}"#] {
            XCTAssertThrowsError(try AuthorizationPlan.validateResult(Data(response.utf8))) { error in
                XCTAssertEqual((error as? BackendProblem)?.code, "authorization_failed")
                XCTAssertFalse(error.localizedDescription.contains("sensitive-fixture"))
            }
        }
    }
    func testShellQuotingPreservesUntrustedPathAsLiteral() throws {
        let value = "directory' $(printf injected)\nwith spaces"
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + AuthorizationPlan.shellQuote(value)]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: data, encoding: .utf8), value)
    }
    func testInstallPlanIsBoundedAndNeverExecutedByPreparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ng-test-' " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data("temporary payload, not an executable".utf8).write(to: helpers.appendingPathComponent("nebula-gui-helper"))
        let plan = try AuthorizationPlan.install(bundle: root, uid: 501)
        XCTAssertTrue(plan.script.contains("-health"))
        XCTAssertTrue(plan.script.contains("published"))
        XCTAssertTrue(plan.script.contains(".install-lock"))
        XCTAssertTrue(plan.script.contains("shasum -a 256"))
        XCTAssertTrue(plan.script.contains("codesign --verify --strict"))
        XCTAssertTrue(plan.script.contains("sudo -u '#501'"))
        XCTAssertFalse(plan.script.contains("chmod 777"))
        XCTAssertTrue(plan.appleScript.contains("with administrator privileges"))
        try checkShellSyntax(plan.script)
        // -n parses only; no installer, administrator dialog, helper, or launchd job is run.
        try checkShellSyntax(AuthorizationPlan.uninstall().script)
    }
    func testInstallRequiresNonRootControllerAndBundledPayload() throws {
        XCTAssertThrowsError(try AuthorizationPlan.install(bundle: URL(fileURLWithPath: "/missing"), uid: 0))
        XCTAssertThrowsError(try AuthorizationPlan.install(bundle: URL(fileURLWithPath: "/missing"), uid: 501))
    }
    func testAuthorizationStateDecodesThroughRealProtocolEnvelope() throws {
        let data = Data(#"{"version":1,"id":"a","result":{"available":false,"reason":"not_installed"}}"#.utf8)
        let status = try Wire.decode(AuthorizationState.self, from: data, requestID: "a")
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.reason, "not_installed")
    }
    func testRecoveryFollowsTheBackendReleaseCheck() throws {
        func state(_ body: String) throws -> AuthorizationState {
            try Wire.decode(AuthorizationState.self, from: Data(#"{"version":1,"id":"a","result":\#(body)}"#.utf8), requestID: "a")
        }
        XCTAssertTrue(try state(#"{"available":true,"helperRelease":"9.9.9","updateRequired":false}"#).supportsRecovery)
        XCTAssertFalse(try state(#"{"available":true,"helperRelease":"0.3.0","updateRequired":true}"#).supportsRecovery)
        XCTAssertFalse(try state(#"{"available":true,"helperRelease":"0.3.0"}"#).supportsRecovery)
        XCTAssertFalse(try state(#"{"available":false,"updateRequired":false}"#).supportsRecovery)
    }
    func testAbnormalBackendExitIsNotSuccessfulCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("exit-failure")
        let script = #"""
        #!/bin/sh
        IFS= read -r line
        request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
        printf '{"version":1,"id":"%s","result":[]}\n' "$request_id"
        IFS= read -r ignored || exit 1
        exit 1
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let client = BackendClient(executable: helper, store: directory.appendingPathComponent("store"))
        _ = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
        do { try await client.shutdown(); XCTFail("Exit 1 must not confirm tunnel cleanup") }
        catch { XCTAssertEqual((error as? BackendProblem)?.code, "cleanup_incomplete") }
        do {
            _ = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
            XCTFail("Abnormal exit warning must remain locked")
        } catch { XCTAssertEqual((error as? BackendProblem)?.code, "cleanup_incomplete") }
    }
    private func checkShellSyntax(_ script: String) throws {
        let process = Process(); let input = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-n"]
        process.standardInput = input; process.standardError = errors
        try process.run(); try input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try input.fileHandleForWriting.close()
        let error = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: error, encoding: .utf8) ?? "shell syntax failure")
    }
}
