import XCTest
import NebulaClient
import CoreGraphics
@testable import NebulaGUI

extension AppModelTests {
    func testKernelLogsAreFetchedOnlyWhileTheLogsPageIsOpen() async throws {
        let backend = controlledBackend(), model = try model(backend)
        await model.refreshLogs() // Hidden page: ControlledBackend fails on any request.
        XCTAssertNil(model.kernelLogs)
        model.logsVisible = true
        let requested = backend.expect("logs")
        let task = Task { await model.refreshLogs() }
        await fulfillment(of: [requested], timeout: 2)
        try backend.replyJSON("logs", data: Data(#"{"available":true,"entries":[{"seq":1,"time":"2026-11-07T07:00:00Z","level":"warn","message":"Handshake timed out","fields":[{"key":"vpnAddrs","value":"[10.1.0.2]"}],"hidden":1}]}"#.utf8))
        await task.value
        XCTAssertEqual(model.kernelLogs?.entries.first?.message, "Handshake timed out")
        // A failed read keeps the last page and never touches connection state.
        let again = backend.expect("logs")
        let failing = Task { await model.refreshLogs() }
        await fulfillment(of: [again], timeout: 2)
        backend.fail("logs", code: "storage_error")
        await failing.value
        XCTAssertEqual(model.kernelLogs?.entries.count, 1)
        XCTAssertNil(model.problem)
        _ = await model.shutdown()
    }
    func testKernelLogNoticeExplainsAnOutdatedHelper() throws {
        let model = try model(controlledBackend())
        let decode = { (json: String) in try JSONDecoder().decode(KernelLogPage.self, from: Data(json.utf8)) }
        XCTAssertEqual(model.kernelLogNotice, "正在读取…")
        // Real device (#59): an old helper relays nothing, yet the backend reports available.
        model.kernelLogs = try decode(#"{"available":true,"entries":[]}"#)
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true,"helperRelease":"0.3.1","updateRequired":true}"#.utf8))
        XCTAssertEqual(model.kernelLogNotice, "当前连接后台不提供内核日志，升级连接后台后可查看。")
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true,"updateRequired":false}"#.utf8))
        XCTAssertEqual(model.kernelLogNotice, "暂无内核日志。连接网络后，Nebula 的启动、握手和错误信息会显示在这里。")
        model.kernelLogs = try decode(#"{"available":false,"entries":[]}"#)
        XCTAssertEqual(model.kernelLogNotice, "当前连接后台不提供内核日志。")
        model.kernelLogs = try decode(#"{"available":true,"entries":[{"seq":1,"time":"2026-11-08T01:00:00Z","level":"info","message":"x","fields":[]}]}"#)
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true,"updateRequired":true}"#.utf8))
        XCTAssertNil(model.kernelLogNotice, "entries are shown even while an upgrade is pending")
    }
    func testLogsPageIsFourthTabWithCommandFour() {
        XCTAssertEqual(WorkspacePage.allCases.map(\.title), ["概览", "节点", "配置", "日志"])
        XCTAssertEqual(WorkspacePage.allCases.map(\.shortcut), ["1", "2", "3", "4"])
        XCTAssertEqual(WorkspacePage(rawValue: "logs"), .logs)
    }
    func testOriginalMarkKeepsNodeAndArmOverlapsSolid() {
        let path = NebulaGlyph.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        for point in [CGPoint(x: 50, y: 48), CGPoint(x: 20, y: 24), CGPoint(x: 13, y: 24), CGPoint(x: 80, y: 24), CGPoint(x: 87, y: 24),
                      CGPoint(x: 50, y: 82), CGPoint(x: 35, y: 36), CGPoint(x: 50, y: 65)] {
            XCTAssertTrue(path.contains(point), "Unexpected hole at \(point)")
        }
    }
    func testViewingAnotherNetworkDoesNotClaimItIsConnectedOrSendRequests() throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = started()
        let connected = ConnectionPresentation(model: model, profileID: model.selectedID)
        XCTAssertEqual(connected.tone, .connected)
        model.selectedID = "second"
        let selected = ConnectionPresentation(model: model, profileID: model.selectedID)
        XCTAssertEqual(selected.tone, .neutral)
        XCTAssertEqual(selected.title, "此网络未连接")
        XCTAssertTrue(selected.detail.contains(model.active!.name))
        XCTAssertEqual(model.connectionActionTitle, "切换并连接")
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertEqual(model.status.profileID, "first")
        // The menu shows the active network, regardless of the main selection.
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: model.active?.id).tone, .connected)
    }
    func testHealthFailureKeepsObservedTunnelStatusAndDisconnectAction() throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = started(); model.authorization = .missing
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: model.selectedID).tone, .connected)
        XCTAssertEqual(model.connectionActionTitle, "断开连接")
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testInFlightConnectionDoesNotAdvertiseLastSnapshotAsReady() throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = started(); model.connectionBusy = true; model.busy = true
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: model.selectedID).title, "正在处理连接")
        XCTAssertTrue(model.canCancelConnection)
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testCleanupUncertaintyIsVisibleBeforeTryingAgain() throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = ConnectionStatus(state: "failed", profileID: "first",
            error: BackendProblem(code: "cleanup_incomplete", message: "Test"), peers: [])
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: model.selectedID).tone, .attention)
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: model.selectedID).title, "连接未完成")
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testFailureOfAnotherNetworkIsAttributedToThatNetwork() throws {
        let backend = controlledBackend(), model = try model(backend)
        model.profiles = [try profile("first", name: "研发网络"), try profile("second", name: "家庭网络")]
        model.status = ConnectionStatus(state: "failed", profileID: "first",
            error: BackendProblem(code: "cleanup_incomplete", message: "Test"), peers: [])
        model.selectedID = "second"
        let other = ConnectionPresentation(model: model, profileID: "second")
        XCTAssertEqual(other.title, "此网络未连接")
        XCTAssertEqual(other.tone, .neutral)
        XCTAssertTrue(other.detail.contains("研发网络"))
        XCTAssertEqual(ConnectionPresentation(model: model, profileID: "first").title, "连接未完成")
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testRecoveryOfAnotherNetworkIsAttributedToThatNetwork() async throws {
        let backend = controlledBackend(), clock = RecoveryClock()
        let model = AppModel(client: backend, now: { clock.date }, wait: { try await clock.wait($0) })
        model.profiles = [try profile("first", name: "研发网络"), try profile("second", name: "家庭网络")]
        model.selectedID = "first"
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true}"#.utf8))
        let starting = backend.expect("connect")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [starting], timeout: 2)
        backend.fail("connect", code: "backend_stopped"); await task.value
        await fulfillment(of: [clock.requested], timeout: 2)
        model.selectedID = "second"
        let calls = backend.calls.count
        func assertRecoveryAttributedToFirst() {
            let other = ConnectionPresentation(model: model, profileID: "second")
            XCTAssertEqual(other.title, "此网络未连接")
            XCTAssertEqual(other.tone, .neutral)
            XCTAssertTrue(other.detail.contains("研发网络"), other.detail)
            XCTAssertEqual(ConnectionPresentation(model: model, profileID: "first").title, "等待恢复")
            XCTAssertTrue(model.canCancelConnection)
        }
        assertRecoveryAttributedToFirst()
        XCTAssertEqual(backend.calls.count, calls)
        // A cleared recovery attempt drops status.profileID; the menu then falls back to the selection.
        let recovering = backend.expect("recover")
        clock.requested = XCTestExpectation(description: "retry rescheduled"); clock.advance()
        await fulfillment(of: [recovering], timeout: 2)
        let reconnecting = backend.expect("connect")
        try backend.reply("recover", ConnectionStatus.disconnected)
        await fulfillment(of: [reconnecting], timeout: 2)
        backend.fail("connect", code: "backend_stopped")
        await fulfillment(of: [clock.requested], timeout: 2)
        XCTAssertNil(model.status.profileID)
        XCTAssertEqual((model.active ?? model.selected)?.id, "second")
        assertRecoveryAttributedToFirst()
        XCTAssertEqual(backend.calls.map(\.method), ["connect", "recover", "connect"])
        XCTAssertEqual(backend.calls.last?.profileID, "first")
        _ = await model.shutdown(); clock.cancel()
    }
    func testMenuShowsTheNetworkItsActionTargets() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.profiles = [try profile("first", name: "研发网络"), try profile("second", name: "家庭网络")]
        model.status = ConnectionStatus(state: "failed", profileID: "first",
            error: BackendProblem(code: "cleanup_incomplete", message: "Test"), peers: [])
        model.selectedID = "second"
        XCTAssertEqual(model.menuProfile?.id, "second")
        let shown = ConnectionPresentation(model: model, profileID: model.menuProfile?.id)
        XCTAssertTrue(shown.detail.contains("研发网络"), shown.detail)
        XCTAssertEqual(model.menuActionTitle, "连接所选网络")
        XCTAssertTrue(backend.calls.isEmpty)
        // The menu action connects exactly the network the menu shows.
        let recovering = backend.expect("recover")
        let task = Task { await model.connectSelected() }
        await fulfillment(of: [recovering], timeout: 2)
        let connecting = backend.expect("connect")
        try backend.reply("recover", ConnectionStatus.disconnected)
        await fulfillment(of: [connecting], timeout: 2)
        XCTAssertEqual(backend.calls.last?.profileID, model.menuProfile?.id)
        try backend.reply("connect", started("second")); await task.value
        // Once started, the menu shows the active network and its action disconnects.
        model.selectedID = "first"
        XCTAssertEqual(model.menuProfile?.id, "second")
        XCTAssertEqual(model.menuActionTitle, "断开连接")
        _ = await model.shutdown()
    }
}
