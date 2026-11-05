import XCTest
import NebulaClient
@testable import NebulaGUI

extension AppModelTests {
    /// A rejected notification action is reported where it happened. A global problem would
    /// outlive a later permission change and contradict the refreshed notification status.
    func testNotificationFailuresStayInTheNotificationSection() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.problem = BackendProblem(code: "cleanup_incomplete", message: "Test")
        await model.sendTestNotification()
        XCTAssertEqual(model.problem?.code, "cleanup_incomplete")
        XCTAssertEqual(model.notificationText, "隔离测试实例不发送系统通知。")
        XCTAssertFalse(model.notificationsBusy)
        model.problem = nil
        await model.setNotifications(true)
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(model.notificationText, "隔离测试实例不发送系统通知。")
        XCTAssertTrue(backend.calls.isEmpty)
        _ = await model.shutdown()
    }
}
