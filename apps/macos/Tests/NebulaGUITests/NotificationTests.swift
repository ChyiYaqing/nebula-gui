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

@MainActor private final class RecordingReminderDelivery: ReminderDelivery {
    var pending: Set<String> = []
    var removed: [String] = []
    var pendingQueries = 0
    func authorized() async -> Bool { true }
    func pendingIdentifiers() async -> [String] { pendingQueries += 1; return Array(pending) }
    func remove(_ identifiers: [String]) { removed += identifiers; pending.subtract(identifiers) }
    func add(_ reminder: CertificateReminder, now: Date) async throws { pending.insert(reminder.id) }
}

extension AppModelTests {
    /// A foreground event can arrive before the first network list. An empty plan at
    /// that point would withdraw every reminder and clear its de-duplication history.
    func testReminderSyncWaitsForTheFirstNetworkList() async throws {
        let suite = "nebula.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "certificateNotificationsEnabled")
        let network = try profile("first")
        let delivery = RecordingReminderDelivery()
        delivery.pending = Set(CertificateReminders.plan(profiles: [network], now: Date()).map(\.id))
        XCTAssertFalse(delivery.pending.isEmpty)
        let backend = controlledBackend()
        let model = AppModel(client: backend, notifications: CertificateNotifications(defaults: defaults, delivery: delivery))
        await model.refreshNotifications()
        XCTAssertEqual(delivery.pendingQueries, 0)
        XCTAssertTrue(delivery.removed.isEmpty)
        let listing = backend.expect("list")
        let loading = Task { await model.refresh() }
        await fulfillment(of: [listing], timeout: 2)
        let querying = backend.expect("status")
        try backend.reply("list", [network])
        await fulfillment(of: [querying], timeout: 2)
        let checking = backend.expect("authorization")
        try backend.reply("status", ConnectionStatus.disconnected)
        await fulfillment(of: [checking], timeout: 2)
        try backend.replyJSON("authorization", data: Data(#"{"available":true}"#.utf8))
        await loading.value
        XCTAssertEqual(delivery.pendingQueries, 1)
        XCTAssertTrue(delivery.removed.isEmpty)
        XCTAssertEqual(delivery.pending, Set(CertificateReminders.plan(profiles: [network], now: Date()).map(\.id)))
        XCTAssertEqual(model.notificationText, "已开启 30／7／1 天及到期提醒")
        _ = await model.shutdown()
    }
}
