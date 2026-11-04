import Foundation
import UserNotifications
import NebulaClient

private final class NotificationPresentation: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresentation()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor private final class SystemReminderDelivery: ReminderDelivery {
    private lazy var center = UNUserNotificationCenter.current()
    func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func remove(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func add(_ reminder: CertificateReminder, now: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.days == 0 ? "Nebula 网络证书已到期" : "Nebula 网络证书即将到期"
        content.body = reminder.days == 0 ? "请打开 Nebula，更新已到期的网络配置。" : "有一份网络证书将在 \(reminder.days) 天内到期，请联系管理员更新。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSince(now)), repeats: false)
        try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }
}

@MainActor final class CertificateNotifications {
    private let defaults: UserDefaults
    private let allowDelivery: Bool
    private let enabledKey = "certificateNotificationsEnabled"
    private let ledgerKey = "certificateNotificationLedger"
    private lazy var coordinator = ReminderCoordinator(delivery: SystemReminderDelivery(), history: defaults.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:])
    var enabled: Bool { allowDelivery && defaults.bool(forKey: enabledKey) }
    var permissionAllowed: Bool { coordinator.permissionAllowed }
    init(defaults: UserDefaults = .standard, allowDelivery: Bool = true) {
        self.defaults = defaults; self.allowDelivery = allowDelivery
        if allowDelivery { UNUserNotificationCenter.current().delegate = NotificationPresentation.shared }
    }
    func enable() async throws -> Bool {
        guard allowDelivery else { throw BackendProblem(code: "notifications_isolated", message: "隔离测试实例不发送系统通知。") }
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        defaults.set(allowed, forKey: enabledKey)
        return allowed
    }
    func sendTest() async throws {
        guard allowDelivery else { throw BackendProblem(code: "notifications_isolated", message: "隔离测试实例不发送系统通知。") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw BackendProblem(code: "notifications_denied", message: "系统未允许通知，请在系统设置中允许 Nebula 通知。")
        }
        let content = UNMutableNotificationContent()
        content.title = "Nebula 测试通知"
        content.body = "这是你刚刚发送的 Nebula 测试通知。"
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "nebula.test.notification", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }
    func disable() async {
        guard allowDelivery else { return }
        defaults.set(false, forKey: enabledKey)
        try? await coordinator.synchronize([], enabled: false, now: Date())
        defaults.set(coordinator.history, forKey: ledgerKey)
    }
    func synchronize(_ profiles: [NetworkProfile]) async throws {
        guard allowDelivery else { return }
        let now = Date()
        try await coordinator.synchronize(CertificateReminders.plan(profiles: profiles, now: now), enabled: enabled, now: now)
        defaults.set(coordinator.history, forKey: ledgerKey)
    }
}
