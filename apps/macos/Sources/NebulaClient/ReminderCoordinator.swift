import Foundation

@MainActor public protocol ReminderDelivery: AnyObject {
    func authorized() async -> Bool
    func pendingIdentifiers() async -> [String]
    func add(_ reminder: CertificateReminder, now: Date) async throws
    func remove(_ identifiers: [String])
}

/// Serializes desired notification state across async system callbacks. An old
/// add which completes after disable/removal is explicitly withdrawn again.
@MainActor public final class ReminderCoordinator {
    private let delivery: any ReminderDelivery
    private var generation: UInt64 = 0
    private var enabled = false
    private var desired: Set<String> = []
    public private(set) var history: [String: Double]
    public private(set) var permissionAllowed = false
    public init(delivery: any ReminderDelivery, history: [String: Double] = [:]) {
        self.delivery = delivery; self.history = history
    }
    public func synchronize(_ reminders: [CertificateReminder], enabled: Bool, now: Date) async throws {
        generation &+= 1
        let token = generation
        self.enabled = enabled
        desired = enabled ? Set(reminders.map(\.id)) : []
        if enabled {
            let allowed = await delivery.authorized()
            guard token == generation else { return }
            permissionAllowed = allowed
            if !allowed { return }
        }
        let pending = Set(await delivery.pendingIdentifiers().filter { $0.hasPrefix(CertificateReminders.identifierPrefix) })
        guard token == generation else { return }
        delivery.remove(pending.subtracting(desired).sorted())
        if !enabled {
            for id in pending { history.removeValue(forKey: id) }
            return
        }
        for reminder in reminders where !pending.contains(reminder.id) {
            guard token == generation, self.enabled else { return }
            if let previous = history[reminder.id], previous <= now.timeIntervalSince1970 { continue }
            try await delivery.add(reminder, now: now)
            guard token == generation, self.enabled else {
                if !self.enabled || !desired.contains(reminder.id) { delivery.remove([reminder.id]) }
                return
            }
            history[reminder.id] = reminder.fireAt.timeIntervalSince1970
        }
        history = Dictionary(uniqueKeysWithValues: history.sorted { $0.value > $1.value }.prefix(256).map { ($0.key, $0.value) })
    }
}
