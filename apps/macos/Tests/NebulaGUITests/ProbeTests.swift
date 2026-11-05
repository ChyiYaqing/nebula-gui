import XCTest
import NebulaClient
@testable import NebulaGUI

extension AppModelTests {
    func session(_ startedAt: String = "2026-11-05T01:00:00Z", _ id: String = "first") -> ConnectionStatus {
        ConnectionStatus(state: "started", profileID: id, error: nil, peers: [], startedAt: startedAt)
    }
    func probeReply(_ address: String, received: Int = 3) -> Data {
        Data(#"{"address":"\#(address)","sent":3,"received":\#(received),"averageMS":\#(received > 0 ? "12.5" : "null"),"observedAt":"2026-11-05T02:00:00Z"}"#.utf8)
    }
    /// Starts a probe on the active network and waits until the request is in flight.
    func startProbe(_ model: AppModel, _ backend: ControlledBackend, _ address: String? = nil) async -> Task<Void, Never> {
        let probing = backend.expect("probe")
        let task = Task { await model.testNode(address) }
        await fulfillment(of: [probing], timeout: 2)
        return task
    }
    func testProbeRejectsInactiveSelection() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session(); model.selectedID = "second"; model.probeAddress = "192.0.2.5"
        await model.testNode()
        await model.testNode("192.0.2.5")
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNil(model.probe)
    }
    func testProbeSuccessIsBoundToItsAddressAndSession() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session(); model.probeAddress = "192.0.2.9"
        let task = await startProbe(model, backend, "192.0.2.5")
        XCTAssertTrue(model.probeBusy)
        XCTAssertEqual(model.currentProbe?.address, "192.0.2.5")
        await model.testNode("192.0.2.6") // A repeated click while busy sends nothing.
        model.probeAddress = "192.0.2.7"
        try backend.replyJSON("probe", data: probeReply("192.0.2.5")); await task.value
        XCTAssertEqual(backend.calls.map(\.address), ["192.0.2.5"])
        XCTAssertFalse(model.probeBusy)
        XCTAssertEqual(model.currentProbe?.address, "192.0.2.5")
        XCTAssertEqual(model.currentProbe?.result?.received, 3)
        XCTAssertEqual(model.probeAddress, "192.0.2.7")
    }
    func testManualTargetIsCapturedWhenTheTestStarts() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session(); model.probeAddress = " 192.0.2.5 "
        let task = await startProbe(model, backend)
        model.probeAddress = "192.0.2.8"
        try backend.replyJSON("probe", data: probeReply("192.0.2.5", received: 0)); await task.value
        XCTAssertEqual(backend.calls.first?.address, "192.0.2.5")
        XCTAssertEqual(model.currentProbe?.address, "192.0.2.5")
        XCTAssertEqual(model.currentProbe?.result?.received, 0)
        XCTAssertNil(model.problem)
    }
    func testProbeFailureStaysLocalAndKeepsUnrelatedProblem() async throws {
        let backend = controlledBackend(), model = try model(backend)
        let unrelated = BackendProblem(code: "rebind_failed", message: "Unrelated")
        model.status = session(); model.problem = unrelated
        let task = await startProbe(model, backend, "192.0.2.5")
        backend.fail("probe", code: "probe_rate_limited"); await task.value
        XCTAssertEqual(model.currentProbe?.problem?.code, "probe_rate_limited")
        XCTAssertEqual(model.problem?.code, unrelated.code)
        XCTAssertFalse(model.probeBusy)
    }
    func testLateProbeSuccessFromReplacedSessionIsDiscarded() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        model.status = session("2026-11-05T02:00:00Z")
        try backend.replyJSON("probe", data: probeReply("192.0.2.5")); await task.value
        XCTAssertNil(model.probe)
        XCTAssertFalse(model.probeBusy)
    }
    func testLateProbeFailureAfterSessionEndsIsDiscarded() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        model.status = .disconnected
        backend.fail("probe", code: "probe_failed"); await task.value
        XCTAssertNil(model.problem)
        XCTAssertNil(model.probe)
    }
    func testPreviousSessionResultIsNotShownAfterReconnect() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        try backend.replyJSON("probe", data: probeReply("192.0.2.5")); await task.value
        XCTAssertNotNil(model.currentProbe)
        model.status = session("2026-11-05T03:00:00Z") // e.g. automatic recovery restarted the tunnel
        XCTAssertNil(model.currentProbe)
    }
    func testDisconnectDiscardsInFlightProbe() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        let stopping = backend.expect("disconnect")
        let disconnecting = Task { await model.disconnect() }
        await fulfillment(of: [stopping], timeout: 2)
        try backend.reply("disconnect", ConnectionStatus.disconnected); await disconnecting.value
        try backend.replyJSON("probe", data: probeReply("192.0.2.5")); await task.value
        XCTAssertNil(model.probe)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.status.state, "disconnected")
    }
    func testSwitchDiscardsLateProbeFromPreviousNetwork() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        model.selectedID = "second"
        let stopping = backend.expect("disconnect")
        let switching = Task { await model.connectSelected() }
        await fulfillment(of: [stopping], timeout: 2)
        let connecting = backend.expect("connect")
        try backend.reply("disconnect", ConnectionStatus.disconnected)
        await fulfillment(of: [connecting], timeout: 2)
        try backend.reply("connect", session("2026-11-05T04:00:00Z", "second")); await switching.value
        backend.fail("probe", code: "probe_failed"); await task.value
        XCTAssertNil(model.probe)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.status.profileID, "second")
    }
    func testShutdownDiscardsInFlightProbe() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = session()
        let task = await startProbe(model, backend, "192.0.2.5")
        let closed = await model.shutdown(); await task.value
        XCTAssertTrue(closed)
        XCTAssertNil(model.probe)
        XCTAssertNil(model.problem)
    }
}
