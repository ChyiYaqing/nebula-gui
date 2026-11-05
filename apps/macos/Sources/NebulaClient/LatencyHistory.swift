import Foundation

/// One ICMP echo per node from a monitoring round. `measured == false` means the backend
/// could not send it (for example no socket), which is not a lost reply.
public struct LatencySample: Decodable, Sendable {
    public let address: String
    public let measured: Bool
    public let replyMS: Double?
}
public struct LatencyBatch: Decodable, Sendable {
    public let observedAt: String
    public let samples: [LatencySample]
}

/// `replyMS == nil` is a measured echo without a reply.
public struct LatencyPoint: Sendable, Equatable {
    public let time: Date
    public let replyMS: Double?
    public init(time: Date, replyMS: Double?) { self.time = time; self.replyMS = replyMS }
}

/// Describes ICMP replies only; it never claims that a node is online or offline.
public enum LatencyHealth: Sendable, Equatable, CaseIterable {
    case stable, unstable, lossy, silent
}

public struct LatencyStats: Sendable, Equatable {
    public let latest: Double?
    public let minimum: Double?
    public let average: Double?
    public let maximum: Double?
    /// Mean absolute change between consecutive replies.
    public let jitter: Double?
    public let samples: Int
    public let replies: Int
    public var lossPercent: Int { samples > 0 ? Int((Double(samples - replies) / Double(samples) * 100).rounded()) : 0 }
    public let health: LatencyHealth

    init(_ points: [LatencyPoint]) {
        let replies = points.compactMap(\.replyMS)
        samples = points.count; self.replies = replies.count
        latest = points.last?.replyMS
        minimum = replies.min(); maximum = replies.max()
        average = replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count)
        jitter = replies.count < 2 ? nil : zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1)
        let recent = points.suffix(LatencyHistory.recentWindow)
        if recent.allSatisfy({ $0.replyMS == nil }) {
            health = .silent
        } else if recent.contains(where: { $0.replyMS == nil }) {
            health = .lossy
        } else if let jitter, let average, jitter > max(LatencyHistory.jitterFloorMS, average * 0.5) {
            health = .unstable
        } else {
            health = .stable
        }
    }
}

/// In-memory latency history for one connection session; never persisted.
public struct LatencyHistory: Sendable {
    /// 60 rounds at 5 seconds: about five minutes per node.
    public static let capacity = 60
    /// Health looks at the last minute so an old loss does not mark a node for five minutes.
    public static let recentWindow = 12
    public static let jitterFloorMS = 10.0
    public private(set) var points: [String: [LatencyPoint]] = [:]
    public init() {}

    public mutating func record(_ batch: LatencyBatch, at time: Date) {
        for sample in batch.samples where sample.measured {
            var series = points[sample.address] ?? []
            series.append(LatencyPoint(time: time, replyMS: sample.replyMS))
            if series.count > Self.capacity { series.removeFirst(series.count - Self.capacity) }
            points[sample.address] = series
        }
    }
    /// Drops nodes that are no longer monitored, bounding memory to the current targets.
    public mutating func retain(_ addresses: Set<String>) {
        points = points.filter { addresses.contains($0.key) }
    }
    public func stats(for address: String) -> LatencyStats? {
        guard let series = points[address], !series.isEmpty else { return nil }
        return LatencyStats(series)
    }
    /// Median of each node's latest reply; nodes whose last echo was lost are left out.
    public var medianLatestMS: Double? { Self.median(points.values.compactMap { $0.last?.replyMS }) }
    /// One point per monitoring round: the median reply across nodes, nil if none replied.
    public var medianSeries: [LatencyPoint] {
        let rounds = Dictionary(grouping: points.values.joined(), by: \.time)
        return rounds.keys.sorted().suffix(Self.capacity).map { time in
            LatencyPoint(time: time, replyMS: Self.median(rounds[time]!.compactMap(\.replyMS)))
        }
    }
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    public func count(_ health: LatencyHealth) -> Int {
        points.keys.filter { stats(for: $0)?.health == health }.count
    }

    /// Addresses to sample: every address of active tunnels, never pending ones — echo
    /// traffic would make Nebula start a handshake on the user's behalf.
    public static func targets(_ peers: [KnownPeer]) -> [String] {
        var seen = Set<String>()
        return peers.filter { !$0.pending }.flatMap(\.addresses).filter { seen.insert($0).inserted }.prefix(maxTargets).map { $0 }
    }
    public static let maxTargets = 64
}
