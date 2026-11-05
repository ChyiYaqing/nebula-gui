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
    private var latestPlan: [CertificateReminder] = []
    private var latestObservation = Date.distantPast
    private var synchronizing = false
    private var waiting: [CheckedContinuation<Void, Error>] = []
    public private(set) var history: [String: Double]
    public private(set) var permissionAllowed = false
    public init(delivery: any ReminderDelivery, history: [String: Double] = [:]) {
        self.delivery = delivery; self.history = history
    }
    /// Coalesces updates while one system operation is in flight. The active
    /// caller drains the latest plan; every caller returns only once that plan
    /// has been applied, and receives its failure, so disabling cannot return early.
    public func synchronize(_ reminders: [CertificateReminder], enabled: Bool, now: Date) async throws {
        generation &+= 1
        self.enabled = enabled; latestPlan = reminders; latestObservation = now
        guard !synchronizing else {
            try await withCheckedThrowingContinuation { waiting.append($0) }
            return
        }
        synchronizing = true
        var failure: Error?
        while true {
            let token = generation
            failure = nil
            do { try await reconcile(latestPlan, enabled: self.enabled, now: latestObservation, token: token) }
            catch { if token == generation { failure = error } }
            if token == generation { break }
        }
        synchronizing = false
        let waiters = waiting; waiting = []
        for waiter in waiters {
            if let failure { waiter.resume(throwing: failure) } else { waiter.resume() }
        }
        if let failure { throw failure }
    }
    private func reconcile(_ reminders: [CertificateReminder], enabled: Bool, now: Date, token: UInt64) async throws {
        let relevant = Set(reminders.map(\.id))
        history = history.filter { relevant.contains($0.key) }
        let allowed = enabled ? await delivery.authorized() : false
        guard token == generation else { return }
        permissionAllowed = allowed
        let pending = Set(await delivery.pendingIdentifiers().filter { $0.hasPrefix(CertificateReminders.identifierPrefix) })
        guard token == generation else { return }
        // Filter consumed thresholds before applying the pending queue limit.
        let selected = enabled && allowed ? Array(reminders.filter {
            pending.contains($0.id) || (history[$0.id].map { $0 > now.timeIntervalSince1970 } ?? true)
        }.prefix(60)) : []
        let desired = Set(selected.map(\.id))
        let withdrawn = pending.subtracting(desired)
        delivery.remove(withdrawn.sorted())
        for id in withdrawn { history.removeValue(forKey: id) }
        if !enabled || !allowed {
            history = history.filter { $0.value <= now.timeIntervalSince1970 }
            return
        }
        for reminder in selected where !pending.contains(reminder.id) {
            guard token == generation else { return }
            try await delivery.add(reminder, now: now)
            guard token == generation else {
                // No newer add can be in flight: this worker owns system calls.
                // Withdraw the stale result, then drain the latest plan afresh.
                delivery.remove([reminder.id])
                history.removeValue(forKey: reminder.id)
                return
            }
            history[reminder.id] = reminder.fireAt.timeIntervalSince1970
        }
        // Bounded by the current plan (at most four IDs per current certificate).
        history = history.filter { relevant.contains($0.key) }
    }
}
