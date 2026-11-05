import Foundation
import XCTest
@testable import NebulaClient

final class ReminderTests: XCTestCase {
    private func profile(id: String = "network", fingerprint: String = "certificate", expires: Date, rawExpiration: String? = nil) throws -> NetworkProfile {
        let json: [String: Any] = ["id": id, "name": "test", "device": "test", "networks": [], "fingerprint": fingerprint,
                                  "expiresAt": rawExpiration ?? ISO8601DateFormatter().string(from: expires), "importedAt": "", "version": "v1", "digest": "test"]
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
    func testCertificateReplacementRemovalAndCompletePlan() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let first = try profile(expires: now.addingTimeInterval(40 * 86400))
        let updated = try profile(fingerprint: "new-cert", expires: now.addingTimeInterval(40 * 86400))
        XCTAssertTrue(Set(CertificateReminders.plan(profiles: [first], now: now).map(\.id)).isDisjoint(with: CertificateReminders.plan(profiles: [updated], now: now).map(\.id)))
        XCTAssertTrue(CertificateReminders.plan(profiles: [], now: now).isEmpty)
        let profiles = try (0..<100).map { try profile(id: String($0), expires: now.addingTimeInterval(Double($0 + 1) * 86400)) }
        let plans = CertificateReminders.plan(profiles: profiles, now: now)
        XCTAssertGreaterThan(plans.count, 60)
        XCTAssertEqual(plans.map(\.fireAt), plans.map(\.fireAt).sorted())
    }
}

@MainActor private final class DelayedReminderDelivery: ReminderDelivery {
    var pending: Set<String> = []
    var adding: CheckedContinuation<Void, Never>?
    var holdAdd = true
    var addCount = 0
    var allowed = true
    var failAdd = false
    func authorized() async -> Bool { allowed }
    var pendingQueries = 0
    var holdSecondSnapshot = false
    var readingPending: CheckedContinuation<[String], Never>?
    var capturedPending: [String] = []
    func pendingIdentifiers() async -> [String] {
        pendingQueries += 1
        if holdSecondSnapshot && pendingQueries == 2 {
            capturedPending = Array(pending)
            return await withCheckedContinuation { readingPending = $0 }
        }
        return Array(pending)
    }
    func remove(_ identifiers: [String]) { pending.subtract(identifiers) }
    func add(_ reminder: CertificateReminder, now: Date) async throws {
        addCount += 1
        if holdAdd { await withCheckedContinuation { adding = $0 } }
        if failAdd { throw BackendProblem(code: "operation_failed", message: "Test") }
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
        let returned = Flag()
        let disabling = Task { try await coordinator.synchronize([], enabled: false, now: now); returned.value = true }
        for _ in 0..<100 { await Task.yield() }
        // Disabling must not report completion while the earlier system add is outstanding.
        XCTAssertFalse(returned.value)
        delivery.adding?.resume(); delivery.adding = nil
        try await disabling.value
        XCTAssertTrue(delivery.pending.isEmpty)
        XCTAssertTrue(coordinator.history.isEmpty)
        try await first.value
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
        let second = Task { try await coordinator.synchronize([new], enabled: true, now: now) }
        for _ in 0..<100 { await Task.yield() }
        delivery.adding?.resume(); delivery.adding = nil
        try await second.value
        XCTAssertEqual(delivery.pending, Set([new.id]))
        try await first.value
        XCTAssertEqual(delivery.pending, Set([new.id]))
        XCTAssertNil(coordinator.history[old.id])
    }
}


extension ReminderTests {
    @MainActor func testConsumedQueueRefillsBeyondSixtyAndNeverRepeatsAfter256() async throws {
        let delivery = DelayedReminderDelivery(); delivery.holdAdd = false
        let coordinator = ReminderCoordinator(delivery: delivery)
        var now = Date(timeIntervalSince1970: 1_000_000)
        let profiles = try (0..<300).map { try profile(id: "network-\($0)", expires: now.addingTimeInterval(-86400)) }
        for batch in 1...5 {
            try await coordinator.synchronize(CertificateReminders.plan(profiles: profiles, now: now), enabled: true, now: now)
            XCTAssertEqual(delivery.pending.count, 60)
            XCTAssertEqual(delivery.addCount, batch * 60)
            delivery.pending.removeAll() // Simulate requests having fired, without sending notifications.
            now.addTimeInterval(2)
        }
        try await coordinator.synchronize(CertificateReminders.plan(profiles: profiles, now: now), enabled: true, now: now)
        XCTAssertTrue(delivery.pending.isEmpty)
        XCTAssertEqual(delivery.addCount, 300)
        XCTAssertEqual(coordinator.history.count, 300)
        // Removing configurations bounds history to the remaining current plan.
        try await coordinator.synchronize(CertificateReminders.plan(profiles: Array(profiles.prefix(150)), now: now), enabled: true, now: now)
        XCTAssertEqual(coordinator.history.count, 150)
        try await coordinator.synchronize([], enabled: true, now: now)
        XCTAssertTrue(coordinator.history.isEmpty)
    }
    @MainActor func testPermissionRevocationWithdrawsAndAllowsRescheduling() async throws {
        let delivery = DelayedReminderDelivery(); delivery.holdAdd = false
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reminder = CertificateReminder(id: CertificateReminders.identifierPrefix + "permission", fireAt: now.addingTimeInterval(100), days: 1)
        try await coordinator.synchronize([reminder], enabled: true, now: now)
        XCTAssertEqual(delivery.pending, Set([reminder.id]))
        delivery.allowed = false
        try await coordinator.synchronize([reminder], enabled: true, now: now.addingTimeInterval(1))
        XCTAssertFalse(coordinator.permissionAllowed)
        XCTAssertTrue(delivery.pending.isEmpty); XCTAssertTrue(coordinator.history.isEmpty)
        delivery.allowed = true
        try await coordinator.synchronize([reminder], enabled: true, now: now.addingTimeInterval(2))
        XCTAssertTrue(coordinator.permissionAllowed)
        XCTAssertEqual(delivery.pending, Set([reminder.id]))
        XCTAssertEqual(delivery.addCount, 2)
    }
    @MainActor func testQueueNeverExceedsSixtyAndPreservesOtherNotificationIDs() async throws {
        let delivery = DelayedReminderDelivery(); delivery.holdAdd = false
        delivery.pending = ["nebula.test.notification", "other.notification"]
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let profiles = try (0..<100).map { try profile(id: String($0), expires: now.addingTimeInterval(40 * 86400)) }
        try await coordinator.synchronize(CertificateReminders.plan(profiles: profiles, now: now), enabled: true, now: now)
        XCTAssertEqual(delivery.pending.filter { $0.hasPrefix(CertificateReminders.identifierPrefix) }.count, 60)
        XCTAssertTrue(delivery.pending.contains("other.notification"))
        try await coordinator.synchronize([], enabled: false, now: now)
        XCTAssertEqual(delivery.pending, Set(["nebula.test.notification", "other.notification"]))
        XCTAssertFalse(coordinator.permissionAllowed)
    }
    func testThresholdsUseAbsoluteExpiryAcrossTimeZoneRepresentations() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let utc = try profile(expires: now, rawExpiration: "2026-11-05T10:00:00Z")
        let offset = try profile(expires: now, rawExpiration: "2026-11-05T18:00:00+08:00")
        XCTAssertEqual(CertificateReminders.plan(profiles: [utc], now: now), CertificateReminders.plan(profiles: [offset], now: now))
        let expiry = try XCTUnwrap(utc.expiration)
        let due = CertificateReminders.plan(profiles: [utc], now: expiry)
        XCTAssertEqual(due.map(\.days), [0])
        XCTAssertEqual(due.first?.fireAt, expiry.addingTimeInterval(1))
    }
}


extension ReminderTests {
    @MainActor func testLatestPlanSerializesPendingSnapshotAndLateAdd() async throws {
        let delivery = DelayedReminderDelivery(); delivery.holdSecondSnapshot = true
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let old = CertificateReminder(id: CertificateReminders.identifierPrefix + "old", fireAt: now.addingTimeInterval(100), days: 1)
        let first = Task { try await coordinator.synchronize([old], enabled: true, now: now) }
        while delivery.adding == nil { await Task.yield() }
        let new = (0..<60).map { CertificateReminder(id: CertificateReminders.identifierPrefix + "new-\($0)", fireAt: now.addingTimeInterval(50), days: 1) } + [old]
        let returned = Flag()
        let second = Task { try await coordinator.synchronize(new, enabled: true, now: now); returned.value = true }
        for _ in 0..<100 { await Task.yield() }
        // The latest plan is queued without overlapping system calls, and its caller waits for it.
        XCTAssertFalse(returned.value)
        XCTAssertEqual(delivery.addCount, 1)
        delivery.holdAdd = false; delivery.adding?.resume(); delivery.adding = nil
        while delivery.readingPending == nil { await Task.yield() }
        delivery.readingPending?.resume(returning: delivery.capturedPending); delivery.readingPending = nil
        try await first.value; try await second.value
        XCTAssertEqual(delivery.pending.count, 60)
        XCTAssertFalse(delivery.pending.contains(old.id))
        XCTAssertNil(coordinator.history[old.id])
    }
}

extension ReminderTests {
    @MainActor func testWithdrawnFutureRequestsAreBackfilledAfterTheirOriginalDate() async throws {
        let delivery = DelayedReminderDelivery(); delivery.holdAdd = false
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let old = (0..<60).map { CertificateReminder(id: CertificateReminders.identifierPrefix + "old-\($0)", fireAt: now.addingTimeInterval(10), days: 1) }
        let urgent = (0..<60).map { CertificateReminder(id: CertificateReminders.identifierPrefix + "urgent-\($0)", fireAt: now.addingTimeInterval(5), days: 1) }
        try await coordinator.synchronize(old, enabled: true, now: now)
        try await coordinator.synchronize(urgent + old, enabled: true, now: now.addingTimeInterval(1))
        XCTAssertTrue(Set(delivery.pending).isDisjoint(with: old.map(\.id)))
        delivery.pending.removeAll()
        try await coordinator.synchronize(urgent + old, enabled: true, now: now.addingTimeInterval(20))
        XCTAssertEqual(delivery.pending, Set(old.map(\.id)))
    }
}

@MainActor private final class Flag { var value = false }

extension ReminderTests {
    @MainActor func testQueuedCallerReceivesTheLatestPlanFailure() async throws {
        let delivery = DelayedReminderDelivery()
        let coordinator = ReminderCoordinator(delivery: delivery)
        let now = Date()
        let old = CertificateReminder(id: CertificateReminders.identifierPrefix + "old", fireAt: now.addingTimeInterval(100), days: 1)
        let new = CertificateReminder(id: CertificateReminders.identifierPrefix + "new", fireAt: now.addingTimeInterval(100), days: 7)
        let first = Task { try await coordinator.synchronize([old], enabled: true, now: now) }
        while delivery.adding == nil { await Task.yield() }
        let second = Task { try await coordinator.synchronize([new], enabled: true, now: now) }
        for _ in 0..<100 { await Task.yield() }
        delivery.holdAdd = false; delivery.failAdd = true
        delivery.adding?.resume(); delivery.adding = nil
        for task in [first, second] {
            do { try await task.value; XCTFail("A failed latest plan was reported as applied") }
            catch { XCTAssertEqual((error as? BackendProblem)?.code, "operation_failed") }
        }
        XCTAssertTrue(delivery.pending.isEmpty)
    }
}
