import XCTest
import NebulaClient
import CoreGraphics
@testable import NebulaGUI

extension AppModelTests {
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
}
