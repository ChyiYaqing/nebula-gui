import Foundation

public struct CertificateReminder: Sendable, Equatable {
    public let id: String
    public let fireAt: Date
    public let days: Int
}
public enum CertificateReminders {
    public static let identifierPrefix = "nebula.cert."
    public static func plan(profiles: [NetworkProfile], now: Date) -> [CertificateReminder] {
        var result: [CertificateReminder] = []
        for profile in profiles {
            guard let expiration = profile.expiration else { continue }
            var due: Int?
            for days in [30, 7, 1, 0] {
                let date = expiration.addingTimeInterval(-Double(days) * 86400)
                if date <= now { due = days; continue }
                result.append(CertificateReminder(id: identifierPrefix + profile.id + "." + profile.fingerprint + ".\(days)", fireAt: date, days: days))
            }
            // Joining with a certificate already near expiry emits only its
            // most urgent current reminder, rather than every past threshold.
            if let days = due {
                result.append(CertificateReminder(id: identifierPrefix + profile.id + "." + profile.fingerprint + ".\(days)", fireAt: now.addingTimeInterval(1), days: days))
            }
        }
        return result.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }
    }
}
