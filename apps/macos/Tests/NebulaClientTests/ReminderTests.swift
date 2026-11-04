import Foundation
import XCTest
@testable import NebulaClient

final class ReminderTests: XCTestCase {
    private func profile(id: String = "network", fingerprint: String = "certificate", expires: Date) throws -> NetworkProfile {
        let json: [String: Any] = ["id": id, "name": "test", "device": "test", "networks": [], "fingerprint": fingerprint,
                                  "expiresAt": ISO8601DateFormatter().string(from: expires), "importedAt": "", "version": "v1", "digest": "test"]
        return try JSONDecoder().decode(NetworkProfile.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testOnlyMostUrgentPastThresholdIsEmitted() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let soon = try profile(expires: now.addingTimeInterval(5 * 86400))
        let plans = CertificateReminders.plan(profiles: [soon], now: now)
        XCTAssertEqual(Set(plans.map(\.days)), Set([7, 1, 0]))
        XCTAssertEqual(plans.first?.days, 7)
        let expired = try profile(expires: now.addingTimeInterval(-1))
        XCTAssertEqual(CertificateReminders.plan(profiles: [expired], now: now).map(\.days), [0])
    }
    func testCertificateReplacementRemovalAndGlobalLimit() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let first = try profile(expires: now.addingTimeInterval(40 * 86400))
        let updated = try profile(fingerprint: "new-cert", expires: now.addingTimeInterval(40 * 86400))
        XCTAssertTrue(Set(CertificateReminders.plan(profiles: [first], now: now).map(\.id)).isDisjoint(with: CertificateReminders.plan(profiles: [updated], now: now).map(\.id)))
        XCTAssertTrue(CertificateReminders.plan(profiles: [], now: now).isEmpty)
        let profiles = try (0..<100).map { try profile(id: String($0), expires: now.addingTimeInterval(Double($0 + 1) * 86400)) }
        let plans = CertificateReminders.plan(profiles: profiles, now: now)
        XCTAssertEqual(plans.count, 60)
        XCTAssertEqual(plans.map(\.fireAt), plans.map(\.fireAt).sorted())
    }
}

@MainActor private final class DelayedReminderDelivery: ReminderDelivery {
    var pending: Set<String> = []
    var adding: CheckedContinuation<Void, Never>?
    var holdAdd = true
    var addCount = 0
    func authorized() async -> Bool { true }
    func pendingIdentifiers() async -> [String] { Array(pending) }
    func remove(_ identifiers: [String]) { pending.subtract(identifiers) }
    func add(_ reminder: CertificateReminder, now: Date) async throws {
        addCount += 1
        if holdAdd { await withCheckedContinuation { adding = $0 } }
        pending.insert(reminder.id)
    }
}

extension ReminderTests {
    @MainActor func testDisableWithdrawsLateSystemAdd() async throws {
        let delivery = DelayedReminderDelivery()
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let reminder = CertificateReminder(id: CertificateReminders.identifierPrefix + "test", fireAt: now, days: 1)
        let first = Task { try await coordinator.synchronize([reminder], enabled: true, now: now) }
        while delivery.adding == nil { await Task.yield() }
        try await coordinator.synchronize([], enabled: false, now: now)
        delivery.adding?.resume(); delivery.adding = nil
        try await first.value
        XCTAssertTrue(delivery.pending.isEmpty)
        XCTAssertTrue(coordinator.history.isEmpty)
    }
    @MainActor func testNewPlanCannotBeOverwrittenByOldAdd() async throws {
        let delivery = DelayedReminderDelivery()
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let old = CertificateReminder(id: CertificateReminders.identifierPrefix + "old", fireAt: now, days: 1)
        let new = CertificateReminder(id: CertificateReminders.identifierPrefix + "new", fireAt: now, days: 7)
        let first = Task { try await coordinator.synchronize([old], enabled: true, now: now) }
        while delivery.adding == nil { await Task.yield() }
        delivery.holdAdd = false
        try await coordinator.synchronize([new], enabled: true, now: now)
        delivery.adding?.resume(); delivery.adding = nil
        try await first.value
        XCTAssertEqual(delivery.pending, Set([new.id]))
        XCTAssertNil(coordinator.history[old.id])
    }
}
