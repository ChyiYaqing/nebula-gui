import Foundation
import XCTest
import NebulaClient
@testable import NebulaGUI

/// Suspends each response until the test chooses its order. No processes or system services.
@MainActor final class ControlledBackend: AppBackend {
    private var expected: [String: [XCTestExpectation]] = [:]
    private var pending: [String: [CheckedContinuation<Data, Error>]] = [:]
    private(set) var calls: [BackendRequest] = []
    private(set) var permanentlyClosed = false
    var shutdownError: Error?
    func expect(_ method: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: method)
        expected[method, default: []].append(expectation)
        return expectation
    }
    func send<T: Decodable & Sendable>(_ request: BackendRequest, as type: T.Type) async throws -> T {
        guard !permanentlyClosed else { throw CancellationError() }
        calls.append(request)
        guard expected[request.method]?.isEmpty == false else {
            XCTFail("Unexpected request: \(request.method)")
            throw BackendProblem(code: "unexpected_request", message: "Unexpected test request")
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            pending[request.method, default: []].append(continuation)
            if expected[request.method]?.isEmpty == false { expected[request.method]?.removeFirst().fulfill() }
        }
        return try JSONDecoder().decode(type, from: data)
    }
    func reply<T: Encodable>(_ method: String, _ value: T) throws {
        try replyJSON(method, data: JSONEncoder().encode(value))
    }
    func replyJSON(_ method: String, data: Data) throws {
        guard pending[method]?.isEmpty == false else { XCTFail("No pending \(method)"); return }
        pending[method]?.removeFirst().resume(returning: data)
    }
    func fail(_ method: String, code: String) {
        guard pending[method]?.isEmpty == false else { XCTFail("No pending \(method)"); return }
        pending[method]?.removeFirst().resume(throwing: BackendProblem(code: code, message: "Controlled failure"))
    }
    func recover() async throws -> ConnectionStatus {
        try await send(BackendRequest(method: "recover"), as: ConnectionStatus.self)
    }
    func completeAuthorizedRemoval() async throws {}
    func shutdown(permanently: Bool) async throws {
        if let shutdownError { throw shutdownError }
        permanentlyClosed = permanently
        let all = pending.values.flatMap { $0 }; pending.removeAll()
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor final class RecoveryClock {
    var date = Date(timeIntervalSince1970: 1000)
    var requested = XCTestExpectation(description: "retry scheduled")
    private var sleeper: CheckedContinuation<Void, Error>?
    func wait(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleeper = continuation; date.addTimeInterval(seconds); requested.fulfill()
        }
    }
    func advance() { let continuation = sleeper; sleeper = nil; continuation?.resume() }
    func cancel() { let continuation = sleeper; sleeper = nil; continuation?.resume(throwing: CancellationError()) }
}

@MainActor final class AppModelTests: XCTestCase {
    func controlledBackend() -> ControlledBackend {
        let backend = ControlledBackend()
        addTeardownBlock {
            await MainActor.run { backend.shutdownError = nil }
            try await backend.shutdown(permanently: true)
        }
        return backend
    }
    func profile(_ id: String, name: String = "Test") throws -> NetworkProfile {
        let data = Data("""
        {"id":"\(id)","name":"\(name)","device":"test","networks":["192.0.2.1/24"],
        "fingerprint":"test","expiresAt":"2030-01-01T00:00:00Z","importedAt":"2026-01-01T00:00:00Z",
        "version":"test","digest":"test"}
        """.utf8)
        return try JSONDecoder().decode(NetworkProfile.self, from: data)
    }
    func model(_ backend: ControlledBackend) throws -> AppModel {
        let model = AppModel(client: backend)
        model.profiles = [try profile("first"), try profile("second")]; model.selectedID = "first"
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true}"#.utf8))
        return model
    }
    func started(_ id: String = "first") -> ConnectionStatus {
        ConnectionStatus(state: "started", profileID: id, error: nil, peers: [])
    }
    /// #84: while another Nebula holds the store, the problem says so; the next successful
    /// poll clears it and loads the networks that could not be listed at launch.
    func testStoreInUseClearsAndLoadsNetworksOnceTheStoreOpens() async throws {
        let backend = controlledBackend()
        let model = AppModel(client: backend)
        let listing = backend.expect("list")
        let launch = Task { await model.refresh() }
        await fulfillment(of: [listing], timeout: 2)
        backend.fail("list", code: "store_in_use")
        await launch.value
        XCTAssertEqual(model.problem?.code, "store_in_use")
        XCTAssertTrue(model.profiles.isEmpty)

        var polling = backend.expect("status")
        var poll = Task { await model.refreshStatus() }
        await fulfillment(of: [polling], timeout: 2)
        backend.fail("status", code: "store_in_use")
        await poll.value
        XCTAssertEqual(model.problem?.code, "store_in_use", "still in use")
        XCTAssertNotEqual(model.problem?.code, "cleanup_incomplete")
        // #86: the connection state is unknown, not failed.
        XCTAssertNotEqual(model.status.state, "failed")
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: nil).title, "无法读取状态")
        XCTAssertEqual(model.menuIconState, .attention)

        polling = backend.expect("status")
        poll = Task { await model.refreshStatus() }
        await fulfillment(of: [polling], timeout: 2)
        let checking = backend.expect("authorization")
        try backend.reply("status", ConnectionStatus.disconnected)
        await fulfillment(of: [checking], timeout: 2)
        let reloading = backend.expect("list")
        try backend.replyJSON("authorization", data: Data(#"{"available":true}"#.utf8))
        await poll.value
        XCTAssertNil(model.problem)
        await fulfillment(of: [reloading], timeout: 2)
        let querying = backend.expect("status")
        try backend.reply("list", [try profile("first")])
        await fulfillment(of: [querying], timeout: 2)
        let authorizing = backend.expect("authorization")
        try backend.reply("status", ConnectionStatus.disconnected)
        await fulfillment(of: [authorizing], timeout: 2)
        try backend.replyJSON("authorization", data: Data(#"{"available":true}"#.utf8))
        for _ in 0..<50 where model.profiles.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.profiles.map(\.id), ["first"])
        XCTAssertNil(model.problem)
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: "first").title, "未连接")
    }

    func testIsolatedInitializationDoesNotLaunchTransportOrServices() throws {
        let backend = controlledBackend(); let model = try model(backend)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(model.status.state, "disconnected")
    }
    func testCancelConnectRejectsLateStartedResponse() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        let connecting = backend.expect("connect")
        let connectTask = Task { await model.connectSelected() }
        await fulfillment(of: [connecting], timeout: 2)
        let disconnecting = backend.expect("disconnect")
        let disconnectTask = Task { await model.disconnect() }
        await fulfillment(of: [disconnecting], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected)
        await disconnectTask.value
        try backend.reply("connect", started())
        await connectTask.value
        XCTAssertEqual(model.status.state, "disconnected")
        XCTAssertFalse(model.busy); XCTAssertFalse(model.canCancelConnection)
        XCTAssertEqual(backend.calls.map(\.method), ["connect", "disconnect"])
        _ = await model.shutdown()
    }
    func testSwitchWaitsForConfirmedCleanupBeforeConnecting() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started(); model.selectedID = "second"
        let stopping = backend.expect("disconnect"), starting = backend.expect("connect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertEqual(backend.calls.map(\.method), ["disconnect"])
        try backend.reply("disconnect", ConnectionStatus.disconnected)
        await fulfillment(of: [starting], timeout: 2)
        XCTAssertEqual(backend.calls.last?.profileID, "second")
        try backend.reply("connect", started("second")); await task.value
        XCTAssertEqual(model.status.profileID, "second")
        _ = await model.shutdown()
    }
    func testSwitchCleanupFailureNeverStartsSecondNetwork() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started(); model.selectedID = "second"; model.automaticRecovery = false
        let stopping = backend.expect("disconnect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [stopping], timeout: 2)
        backend.fail("disconnect", code: "cleanup_incomplete"); await task.value
        XCTAssertEqual(backend.calls.map(\.method), ["disconnect"])
        XCTAssertEqual(model.status.profileID, "first")
        XCTAssertEqual(model.status.error?.code, "cleanup_incomplete")
        _ = await model.shutdown()
    }
    func testShutdownInvalidatesLateConnect() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        let starting = backend.expect("connect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [starting], timeout: 2)
        let clean = await model.shutdown(); await task.value
        XCTAssertTrue(clean); XCTAssertTrue(backend.permanentlyClosed)
        XCTAssertFalse(model.status.isStarted)
        await model.refreshStatus(); await model.connectSelected()
        XCTAssertEqual(backend.calls.count, 1)
    }
    func testLateStatusCannotOverwriteUserDisconnect() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started()
        let refreshing = backend.expect("status")
        let refreshTask = Task { await model.refreshStatus() }
        await fulfillment(of: [refreshing], timeout: 2)
        let stopping = backend.expect("disconnect")
        let stopTask = Task { await model.disconnect() }
        await fulfillment(of: [stopping], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected); await stopTask.value
        try backend.reply("status", started()); await refreshTask.value
        XCTAssertEqual(model.status.state, "disconnected")
        XCTAssertEqual(backend.calls.map(\.method), ["status", "disconnect"])
        _ = await model.shutdown()
    }
    func testDisconnectWhileRetryWaitsNeverReconnects() async throws {
        let backend = controlledBackend(), clock = RecoveryClock()
        let model = AppModel(client: backend, now: { clock.date }, wait: { try await clock.wait($0) })
        model.profiles = [try profile("first")]; model.selectedID = "first"
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true}"#.utf8))
        let starting = backend.expect("connect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [starting], timeout: 2)
        backend.fail("connect", code: "backend_stopped"); await task.value
        await fulfillment(of: [clock.requested], timeout: 2)
        let stopping = backend.expect("disconnect")
        let stopTask = Task { await model.disconnect() }
        await fulfillment(of: [stopping], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected); await stopTask.value
        clock.advance()
        _ = await model.shutdown()
        XCTAssertEqual(backend.calls.map(\.method), ["connect", "disconnect"])
        XCTAssertFalse(model.canCancelConnection)
    }
    /// Await the private task so absence checks need neither sleeps nor scheduler guesses.
    private func networkTask(of model: AppModel) throws -> Task<Void, Never> {
        try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "networkTask" }?.value as? Task<Void, Never>)
    }
    func testNetworkChangeCancelledDuringStatusQueryDoesNotRebind() async throws {
        let backend = controlledBackend(), clock = RecoveryClock()
        let model = AppModel(client: backend, now: { clock.date }, wait: { try await clock.wait($0) })
        model.status = started()
        model.environmentChanged(.network(true))
        let task = try networkTask(of: model)
        await fulfillment(of: [clock.requested], timeout: 2)
        let querying = backend.expect("status")
        clock.advance()
        await fulfillment(of: [querying], timeout: 2)

        model.environmentChanged(.sleep)
        XCTAssertTrue(task.isCancelled)
        let authorizing = backend.expect("authorization")
        try backend.reply("status", started())
        await fulfillment(of: [authorizing], timeout: 2)
        try backend.replyJSON("authorization", data: Data(#"{"available":true,"updateRequired":false}"#.utf8))
        await task.value

        XCTAssertEqual(backend.calls.map(\.method), ["status", "authorization"])
        XCTAssertNil(model.problem)
        _ = await model.shutdown()
    }
    func testNetworkChangeRebindsAndPublishesReturnedStatus() async throws {
        let backend = controlledBackend(), clock = RecoveryClock()
        let model = AppModel(client: backend, now: { clock.date }, wait: { try await clock.wait($0) })
        model.status = started()
        model.environmentChanged(.network(true))
        let task = try networkTask(of: model)
        await fulfillment(of: [clock.requested], timeout: 2)
        let querying = backend.expect("status")
        clock.advance()
        await fulfillment(of: [querying], timeout: 2)
        let authorizing = backend.expect("authorization")
        try backend.reply("status", started())
        await fulfillment(of: [authorizing], timeout: 2)
        let rebinding = backend.expect("rebind")
        try backend.replyJSON("authorization", data: Data(#"{"available":true,"updateRequired":false}"#.utf8))
        await fulfillment(of: [rebinding], timeout: 2)
        var rebound = started()
        rebound.observedAt = "2026-11-12T00:00:00Z"
        try backend.reply("rebind", rebound)
        await task.value

        XCTAssertEqual(backend.calls.map(\.method), ["status", "authorization", "rebind"])
        XCTAssertEqual(model.status, rebound)
        XCTAssertNil(model.problem)
        _ = await model.shutdown()
    }
    func testBackendFailureDuringRecoveryRetainsUncertainState() async throws {
        let backend = controlledBackend(), clock = RecoveryClock()
        let model = AppModel(client: backend, now: { clock.date }, wait: { try await clock.wait($0) })
        model.profiles = [try profile("first")]; model.selectedID = "first"
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true}"#.utf8))
        let starting = backend.expect("connect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [starting], timeout: 2)
        backend.fail("connect", code: "backend_stopped"); await task.value
        await fulfillment(of: [clock.requested], timeout: 2)
        let recovering = backend.expect("recover")
        clock.requested = XCTestExpectation(description: "retry rescheduled"); clock.advance()
        await fulfillment(of: [recovering], timeout: 2)
        backend.fail("recover", code: "cleanup_incomplete")
        await fulfillment(of: [clock.requested], timeout: 2)
        XCTAssertEqual(model.status.state, "failed")
        XCTAssertEqual(model.status.error?.code, "cleanup_incomplete")
        XCTAssertEqual(backend.calls.map(\.method), ["connect", "recover"])
        _ = await model.shutdown(); clock.cancel()
    }
}

extension AppModelTests {
    func testPrimaryDisconnectSurvivesUnavailableAuthorizationHealth() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started(); model.authorization = .missing
        XCTAssertEqual(model.connectionActionTitle, "断开连接")
        XCTAssertEqual(model.menuActionTitle, "断开连接")
        let stopping = backend.expect("disconnect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [stopping], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected); await task.value
        XCTAssertEqual(backend.calls.map(\.method), ["disconnect"])
        XCTAssertEqual(model.status.state, "disconnected")
        XCTAssertFalse(model.showAuthorizationReview)
        _ = await model.shutdown()
    }
    func testMenuDisconnectTargetsActiveNetworkWhenSelectionDiffers() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started(); model.selectedID = "second"; model.authorization = .missing
        XCTAssertEqual(model.menuActionTitle, "断开连接")
        XCTAssertEqual(model.connectionActionTitle, "启用连接后台")
        let stopping = backend.expect("disconnect")
        let task = Task { await model.disconnect() }
        await fulfillment(of: [stopping], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected); await task.value
        XCTAssertEqual(backend.calls.map(\.method), ["disconnect"])
        XCTAssertEqual(model.selectedID, "second")
        XCTAssertEqual(model.status.state, "disconnected")
        _ = await model.shutdown()
    }
    func testUnavailableComponentStillPromptsForNewConnection() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.authorization = .missing
        XCTAssertEqual(model.connectionActionTitle, "启用连接后台")
        XCTAssertEqual(model.menuActionTitle, "启用连接后台")
        await model.connectSelected()
        XCTAssertTrue(model.showAuthorizationReview)
        XCTAssertTrue(backend.calls.isEmpty)
        _ = await model.shutdown()
    }
    /// #97: a finished removal left the review in removal mode for the next "enable".
    func testConnectAfterRemovalOpensReviewInInstallMode() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.authorization = .missing
        model.removingAuthorization = true; model.upgradingAuthorization = true
        await model.connectSelected()
        XCTAssertTrue(model.showAuthorizationReview)
        XCTAssertFalse(model.removingAuthorization)
        XCTAssertFalse(model.upgradingAuthorization)
        XCTAssertTrue(backend.calls.isEmpty)
        _ = await model.shutdown()
    }
    func testFailedPrimaryDisconnectRetainsCleanupUncertainty() async throws {
        let backend = controlledBackend(); let model = try model(backend)
        model.status = started(); model.authorization = .missing; model.automaticRecovery = false
        let stopping = backend.expect("disconnect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [stopping], timeout: 2)
        backend.fail("disconnect", code: "cleanup_incomplete"); await task.value
        XCTAssertEqual(model.status.state, "failed")
        XCTAssertEqual(model.status.profileID, "first")
        XCTAssertEqual(model.problem?.code, "cleanup_incomplete")
        XCTAssertFalse(model.showAuthorizationReview)
        _ = await model.shutdown()
    }
}
