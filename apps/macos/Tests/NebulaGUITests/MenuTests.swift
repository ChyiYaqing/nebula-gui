import XCTest
import AppKit
import NebulaClient
@testable import NebulaGUI

extension AppModelTests {
    private func started(_ id: String, peers: String = "[]") throws -> ConnectionStatus {
        let decoded = try JSONDecoder().decode([KnownPeer].self, from: Data(peers.utf8))
        return ConnectionStatus(state: "started", profileID: id, error: nil, peers: decoded, startedAt: "2026-11-08T05:00:00Z")
    }

    func testMenuIconStatePriority() throws {
        let model = try model(controlledBackend())
        XCTAssertEqual(model.menuIconState, .disconnected)
        model.status = try started("first")
        XCTAssertEqual(model.menuIconState, .connected)
        model.connectionBusy = true
        XCTAssertEqual(model.menuIconState, .connecting, "busy wins over connected")
        model.connectionBusy = false
        model.status = ConnectionStatus(state: "failed", profileID: "first", error: BackendProblem(code: "start_failed", message: "x"), peers: [])
        XCTAssertEqual(model.menuIconState, .attention)
        model.status = .disconnected
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":false}"#.utf8))
        XCTAssertEqual(model.menuIconState, .attention, "a missing component needs attention once a network exists")
        model.profiles = []
        XCTAssertEqual(model.menuIconState, .disconnected)
    }

    func testStatusIconsDifferPerState() {
        func pixels(_ state: MenuIconState) -> Data {
            let image = NebulaGlyph.image(size: 20, state: state)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.accessibilityDescription, state.accessibility)
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }
        let all: [MenuIconState] = [.connected, .connecting, .attention, .disconnected]
        XCTAssertEqual(Set(all.map(pixels)).count, all.count)
    }

    func testMenuVisibilityDrivesSampling() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = try started("first", peers: #"[{"name":"a","addresses":["192.0.2.12"],"pending":false}]"#)
        await model.sampleLatency() // Neither page nor menu visible: no request.
        model.showMenu(true) // Test model: no services, so no timer.
        let requested = backend.expect("sample")
        let task = Task { await model.sampleLatency() }
        await fulfillment(of: [requested], timeout: 2)
        try backend.replyJSON("sample", data: Data(#"{"observedAt":"2026-11-08T05:01:00Z","samples":[{"address":"192.0.2.12","status":"reply","latencyMS":12}]}"#.utf8))
        await task.value
        XCTAssertEqual(model.latency.latest(for: "192.0.2.12")?.ms, 12)
        model.showMenu(false)
        await model.sampleLatency() // Closed again: no further request.
        XCTAssertEqual(backend.calls.filter { $0.method == "sample" }.count, 1)
        _ = await model.shutdown()
    }

    func testMenuSwitchConnectsTheChosenNetwork() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = try started("first"); model.selectedID = "first"
        let unchanged = await model.switchNetwork(to: "first")
        XCTAssertTrue(unchanged, "the current network is a no-op")
        XCTAssertTrue(backend.calls.isEmpty)
        let disconnecting = backend.expect("disconnect"), connecting = backend.expect("connect")
        let task = Task { await model.switchNetwork(to: "second") }
        await fulfillment(of: [disconnecting], timeout: 2)
        XCTAssertTrue(model.busy, "busy while switching, so the menu disables other rows")
        try backend.replyJSON("disconnect", data: Data(#"{"state":"disconnected","peers":[]}"#.utf8))
        await fulfillment(of: [connecting], timeout: 2)
        XCTAssertEqual(backend.calls.last?.profileID, "second")
        try backend.replyJSON("connect", data: Data(#"{"state":"started","profileID":"second","peers":[],"startedAt":"2026-11-08T05:02:00Z"}"#.utf8))
        let switched = await task.value
        XCTAssertTrue(switched)
        XCTAssertEqual(model.status.profileID, "second")
        XCTAssertEqual(model.selectedID, "second")
        _ = await model.shutdown()
    }

    func testMenuSwitchWithoutComponentDefersToTheWindow() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":false}"#.utf8))
        let handled = await model.switchNetwork(to: "second")
        XCTAssertFalse(handled)
        XCTAssertEqual(model.selectedID, "second")
        XCTAssertFalse(model.showAuthorizationReview, "the menu never opens the authorization review itself")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testConnectedDurationText() {
        let now = Date(timeIntervalSince1970: 1_794_117_600) // 2026-11-08T06:00:00Z
        XCTAssertNil(connectedDuration(since: nil, now: now))
        XCTAssertNil(connectedDuration(since: "bad", now: now))
        XCTAssertEqual(connectedDuration(since: "2026-11-08T05:59:40Z", now: now), "刚刚连接")
        XCTAssertEqual(connectedDuration(since: "2026-11-08T05:48:00.5Z", now: now), "已连接 11 分钟")
        XCTAssertEqual(connectedDuration(since: "2026-11-08T04:00:00Z", now: now), "已连接 2 小时")
        XCTAssertEqual(connectedDuration(since: "2026-11-08T03:35:00Z", now: now), "已连接 2 小时 25 分钟")
        XCTAssertEqual(connectedDuration(since: "2026-11-06T03:00:00Z", now: now), "已连接 2 天 3 小时")
    }
}
