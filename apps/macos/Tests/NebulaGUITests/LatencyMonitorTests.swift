import XCTest
import NebulaClient
@testable import NebulaGUI

extension AppModelTests {
    func monitored(_ startedAt: String = "2026-11-05T01:00:00Z") throws -> ConnectionStatus {
        let peers = try JSONDecoder().decode([KnownPeer].self, from: Data(#"""
        [{"name":"a","addresses":["192.0.2.5"],"pending":false},{"name":"b","addresses":["192.0.2.6"],"pending":true}]
        """#.utf8))
        return ConnectionStatus(state: "started", profileID: "first", error: nil, peers: peers, startedAt: startedAt)
    }
    var sampleReply: Data { Data(#"{"observedAt":"2026-11-05T02:00:00Z","samples":[{"address":"192.0.2.5","measured":true,"replyMS":12.5}]}"#.utf8) }

    func testLatencySamplesActiveTunnelsOfTheSession() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = try monitored()
        let sampling = backend.expect("sample")
        let task = Task { await model.sampleLatency() }
        await fulfillment(of: [sampling], timeout: 2)
        XCTAssertEqual(backend.calls.last?.addresses, ["192.0.2.5"])
        try backend.replyJSON("sample", data: sampleReply)
        await task.value
        XCTAssertEqual(model.currentLatency?.stats(for: "192.0.2.5")?.latest, 12.5)
        XCTAssertNil(model.latencyNote)
        // A new connection session starts with an empty history.
        model.status = try monitored("2026-11-05T03:00:00Z")
        XCTAssertNil(model.currentLatency)
    }
    func testLateLatencySampleAfterSessionChangeIsDropped() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.status = try monitored()
        let sampling = backend.expect("sample")
        let task = Task { await model.sampleLatency() }
        await fulfillment(of: [sampling], timeout: 2)
        model.status = try monitored("2026-11-05T03:00:00Z")
        try backend.replyJSON("sample", data: sampleReply)
        await task.value
        XCTAssertTrue(model.latency.points.isEmpty)
        XCTAssertNil(model.currentLatency)
    }
    func testLatencyFailureStaysLocalAndIdleModelsDoNotSample() async throws {
        let backend = controlledBackend(), model = try model(backend)
        model.setLatencyMonitoring(true) // isolated model: never starts a monitoring task
        await model.sampleLatency()       // disconnected: nothing to sample
        XCTAssertTrue(backend.calls.isEmpty)
        model.status = try monitored()
        let sampling = backend.expect("sample")
        let task = Task { await model.sampleLatency() }
        await fulfillment(of: [sampling], timeout: 2)
        backend.fail("sample", code: "probe_rate_limited")
        await task.value
        XCTAssertNotNil(model.latencyNote)
        XCTAssertNil(model.problem)
        model.setLatencyMonitoring(false)
    }
}
