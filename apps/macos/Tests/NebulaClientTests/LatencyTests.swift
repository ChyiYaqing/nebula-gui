import Foundation
import XCTest
@testable import NebulaClient

final class LatencyTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    func batch(_ samples: [(String, Double?)], unmeasured: [String] = []) throws -> LatencyBatch {
        let items = samples.map { address, ms in #"{"address":"\#(address)","measured":true\#(ms.map { #","replyMS":\#($0)"# } ?? "")}"# }
            + unmeasured.map { #"{"address":"\#($0)","measured":false}"# }
        return try JSONDecoder().decode(LatencyBatch.self, from: Data(#"{"observedAt":"2026-11-05T02:00:00Z","samples":[\#(items.joined(separator: ","))]}"#.utf8))
    }
    func history(_ series: [Double?], address: String = "192.0.2.5") throws -> LatencyHistory {
        var history = LatencyHistory()
        for (index, ms) in series.enumerated() { history.record(try batch([(address, ms)]), at: origin.addingTimeInterval(Double(index) * 5)) }
        return history
    }

    func testStatisticsDescribeRepliesOnly() throws {
        let stats = try XCTUnwrap(try history([10, 14, nil, 12]).stats(for: "192.0.2.5"))
        XCTAssertEqual(stats.latest, 12); XCTAssertEqual(stats.minimum, 10); XCTAssertEqual(stats.maximum, 14)
        XCTAssertEqual(try XCTUnwrap(stats.average), 12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.jitter), 3, accuracy: 0.001) // |14-10| and |12-14| between consecutive replies
        XCTAssertEqual(stats.samples, 4); XCTAssertEqual(stats.replies, 3); XCTAssertEqual(stats.lossPercent, 25)
    }
    func testHealthUsesTheRecentWindow() throws {
        XCTAssertEqual(try history(Array(repeating: 20, count: 20)).stats(for: "192.0.2.5")?.health, .stable)
        XCTAssertEqual(try history(Array(repeating: 20, count: 19) + [nil]).stats(for: "192.0.2.5")?.health, .lossy)
        XCTAssertEqual(try history([20] + Array(repeating: nil, count: LatencyHistory.recentWindow)).stats(for: "192.0.2.5")?.health, .silent)
        // A loss older than the window no longer marks the node.
        XCTAssertEqual(try history([nil] + Array(repeating: 20, count: LatencyHistory.recentWindow)).stats(for: "192.0.2.5")?.health, .stable)
        XCTAssertEqual(try history([20, 60, 20, 60, 20]).stats(for: "192.0.2.5")?.health, .unstable)
        // Small absolute jitter on a fast link is not instability.
        XCTAssertEqual(try history([2, 6, 2, 6]).stats(for: "192.0.2.5")?.health, .stable)
    }
    func testHistoryIsBoundedAndIgnoresUnmeasuredEchoes() throws {
        var history = try self.history((0..<(LatencyHistory.capacity + 5)).map { Double($0) })
        XCTAssertEqual(history.points["192.0.2.5"]?.count, LatencyHistory.capacity)
        XCTAssertEqual(history.points["192.0.2.5"]?.first?.replyMS, 5)
        history.record(try batch([], unmeasured: ["192.0.2.5", "192.0.2.6"]), at: origin)
        XCTAssertEqual(history.points["192.0.2.5"]?.count, LatencyHistory.capacity)
        XCTAssertNil(history.points["192.0.2.6"])
        history.retain([])
        XCTAssertTrue(history.points.isEmpty)
    }
    func testMedianAcrossNodesAndRounds() throws {
        var history = LatencyHistory()
        history.record(try batch([("192.0.2.5", 10), ("192.0.2.6", 30), ("192.0.2.7", nil)]), at: origin)
        history.record(try batch([("192.0.2.5", 12), ("192.0.2.6", nil), ("192.0.2.7", 40)]), at: origin.addingTimeInterval(5))
        history.record(try batch([("192.0.2.5", nil), ("192.0.2.6", nil), ("192.0.2.7", nil)]), at: origin.addingTimeInterval(10))
        XCTAssertEqual(history.medianSeries.map(\.replyMS), [20, 26, nil])
        XCTAssertNil(history.medianLatestMS)
        history.record(try batch([("192.0.2.5", 8), ("192.0.2.6", 9), ("192.0.2.7", 30)]), at: origin.addingTimeInterval(15))
        XCTAssertEqual(history.medianLatestMS, 9)
        XCTAssertEqual(history.count(.lossy), 3)
    }
    func testTargetsAreActiveTunnelsOnlyDeduplicatedAndBounded() throws {
        let peers = try JSONDecoder().decode([KnownPeer].self, from: Data(#"""
        [{"name":"a","addresses":["192.0.2.5","192.0.2.6"],"pending":false},
         {"name":"b","addresses":["192.0.2.7"],"pending":true},
         {"name":"c","addresses":["192.0.2.5"],"pending":false}]
        """#.utf8))
        XCTAssertEqual(LatencyHistory.targets(peers), ["192.0.2.5", "192.0.2.6"])
        let many = (0..<100).map { #"{"name":"n","addresses":["10.0.\#($0 / 200).\#($0 % 200)"],"pending":false}"# }
        let large = try JSONDecoder().decode([KnownPeer].self, from: Data("[\(many.joined(separator: ","))]".utf8))
        XCTAssertEqual(LatencyHistory.targets(large).count, LatencyHistory.maxTargets)
    }
}
