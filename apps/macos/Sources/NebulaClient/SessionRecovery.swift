import Foundation

public struct RecoveryAttempt: Sendable, Equatable {
    public let profileID: String
    public let generation: UInt64
    public let number: Int
}

/// In-memory user intent; never restores a connection merely because App launched.
public struct SessionRecovery: Sendable {
    public private(set) var enabled = true
    public private(set) var desiredProfileID: String?
    public private(set) var generation: UInt64 = 0
    public private(set) var attempts = 0
    public private(set) var retryAt: Date?
    public private(set) var sleeping = false
    public private(set) var networkAvailable = true
    private var stableSince: Date?
    public init() {}
    @discardableResult public mutating func userConnect(_ id: String) -> UInt64 {
        generation &+= 1; desiredProfileID = id; attempts = 0; retryAt = nil; stableSince = nil
        return generation
    }
    @discardableResult public mutating func userDisconnect() -> UInt64 {
        generation &+= 1; desiredProfileID = nil; attempts = 0; retryAt = nil; stableSince = nil
        return generation
    }
    public mutating func setEnabled(_ value: Bool) {
        enabled = value; generation &+= 1; retryAt = nil
    }
    public mutating func environment(sleeping: Bool, networkAvailable: Bool) {
        self.sleeping = sleeping; self.networkAvailable = networkAvailable
        if sleeping || !networkAvailable { retryAt = nil }
    }
    public mutating func observedStarted(at now: Date) {
        retryAt = nil
        if let stableSince {
            if now.timeIntervalSince(stableSince) >= 60 { attempts = 0 }
        } else { stableSince = now }
    }
    @discardableResult public mutating func schedule(code: String, at now: Date) -> Date? {
        stableSince = nil
        let recoverable = ["backend_stopped", "backend_unavailable", "cleanup_incomplete", "cleanup_pending", "authorization_required", "rebind_failed"]
        guard enabled, desiredProfileID != nil, !sleeping, networkAvailable, attempts < 5, recoverable.contains(code) else { return nil }
        if retryAt == nil { retryAt = now.addingTimeInterval(pow(2, Double(attempts))) }
        return retryAt
    }
    public mutating func beginAttempt(at now: Date) -> RecoveryAttempt? {
        guard enabled, !sleeping, networkAvailable, let profileID = desiredProfileID,
              let retryAt, retryAt <= now, attempts < 5 else { return nil }
        self.retryAt = nil; attempts += 1
        return RecoveryAttempt(profileID: profileID, generation: generation, number: attempts)
    }
    public func accepts(_ attempt: RecoveryAttempt) -> Bool {
        enabled && desiredProfileID == attempt.profileID && generation == attempt.generation
    }
}
