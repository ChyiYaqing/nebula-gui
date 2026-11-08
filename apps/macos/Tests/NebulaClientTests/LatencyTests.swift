import XCTest
@testable import NebulaClient

final class LatencyTests: XCTestCase {
    private func round(_ samples: [(String, String, Double?)]) -> LatencyRound {
        LatencyRound(observedAt: "2026-11-08T04:00:00Z", samples: samples.map { LatencySample(address: $0.0, status: $0.1, latencyMS: $0.2) })
    }

    func testDecodesBackendRound() throws {
        let data = Data(#"{"version":1,"id":"a","result":{"observedAt":"2026-11-08T04:00:00.1Z","samples":[{"address":"10.73.0.3","status":"reply","latencyMS":9.5},{"address":"10.73.0.4","status":"timeout"}]}}"#.utf8)
        let round = try Wire.decode(LatencyRound.self, from: data, requestID: "a")
        XCTAssertEqual(round.samples.map(\.status), ["reply", "timeout"])
        XCTAssertEqual(round.samples[0].latencyMS, 9.5)
        XCTAssertNil(round.samples[1].latencyMS)
    }

    func testStatsLossAndJitter() {
        var history = LatencyHistory()
        for ms in [10.0, 30.0, nil, 20.0] as [Double?] {
            history.record(round([("a", ms == nil ? "timeout" : "reply", ms)]), session: "s")
        }
        history.record(round([("a", "unavailable", nil), ("a", "unmeasured", nil)]), session: "s") // not points
        let stats = history.stats(for: "a")
        XCTAssertEqual(stats.samples, 4)
        XCTAssertEqual(stats.replies, 3)
        XCTAssertEqual(stats.minimum, 10)
        XCTAssertEqual(stats.average, 20)
        XCTAssertEqual(stats.maximum, 30)
        XCTAssertEqual(stats.jitter, 15) // |30-10| and |20-30| over consecutive replies
        XCTAssertEqual(stats.lossPercent, 25)
        XCTAssertNil(history.stats(for: "missing").lossPercent)
        XCTAssertNil(history.stats(for: "missing").jitter)
    }

    func testRingBufferKeepsLatestSixty() {
        var history = LatencyHistory()
        for i in 0..<75 { history.record(round([("a", "reply", Double(i))]), session: "s") }
        XCTAssertEqual(history.points(for: "a").count, LatencyHistory.capacity)
        XCTAssertEqual(history.points(for: "a").first?.ms, 15)
        XCTAssertEqual(history.latest(for: "a")?.ms, 74)
    }

    func testNewSessionClearsHistory() {
        var history = LatencyHistory()
        history.record(round([("a", "reply", 5)]), session: "first|t1")
        history.record(round([("b", "reply", 7)]), session: "first|t2") // reconnect
        XCTAssertTrue(history.points(for: "a").isEmpty)
        XCTAssertEqual(history.points(for: "b").count, 1)
        history.reset()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.session)
    }

    func testGradesAndSummary() {
        XCTAssertEqual(LatencyGrade.of(nil), .silent)
        XCTAssertEqual(LatencyGrade.of(49.9), .good)
        XCTAssertEqual(LatencyGrade.of(50), .fair)
        XCTAssertEqual(LatencyGrade.of(150), .poor)
        var history = LatencyHistory()
        history.record(round([("a", "reply", 8), ("b", "reply", 80), ("c", "timeout", nil), ("d", "reply", 300)]), session: "s")
        let summary = history.summary(addresses: ["a", "b", "c", "d", "never"])
        XCTAssertEqual(summary.median, 80)
        XCTAssertEqual(summary.grades, [.good: 1, .fair: 1, .silent: 1, .poor: 1])
        history.record(round([("a", "reply", 10)]), session: "s")
        XCTAssertEqual(history.summary(addresses: ["a", "b"]).median, 45) // even count: mean of the middle two
    }

    func testTargetsSkipPendingDeduplicateAndBound() throws {
        let peers = try JSONDecoder().decode([KnownPeer].self, from: Data(#"[{"name":"a","addresses":["10.0.0.2","10.0.0.3"],"pending":false},{"name":"p","addresses":["10.0.0.9"],"pending":true},{"name":"dup","addresses":["10.0.0.2"],"pending":false}]"#.utf8))
        XCTAssertEqual(LatencyTargets.of(peers), ["10.0.0.2", "10.0.0.3"])
        let many = (0..<100).map { KnownPeer(name: "n\($0)", addresses: ["10.1.\($0 / 250).\($0 % 250 + 1)"], pending: false) }
        XCTAssertEqual(LatencyTargets.of(many).count, LatencyTargets.limit)
    }
}
