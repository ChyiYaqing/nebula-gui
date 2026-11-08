import Foundation

/// One `sample` round from the backend: one ICMP echo per active peer address.
public struct LatencySample: Decodable, Sendable, Equatable {
    public let address: String
    /// reply, timeout (no ICMP reply), unavailable (could not send), unmeasured (round limit).
    public let status: String
    public let latencyMS: Double?
    public init(address: String, status: String, latencyMS: Double?) {
        self.address = address; self.status = status; self.latencyMS = latencyMS
    }
}
public struct LatencyRound: Decodable, Sendable, Equatable {
    public let observedAt: String
    public let samples: [LatencySample]
    public init(observedAt: String, samples: [LatencySample]) { self.observedAt = observedAt; self.samples = samples }
}

/// `ms == nil` means the echo got no reply. Rounds that could not measure are not points.
public struct LatencyPoint: Sendable, Equatable {
    public let ms: Double?
    /// When the backend finished the round; nil if its timestamp could not be parsed.
    public let at: Date?
    public init(ms: Double?, at: Date? = nil) { self.ms = ms; self.at = at }
}

private let fractionalTime: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let plainTime = ISO8601DateFormatter()

/// Describes ICMP replies only; never whether a node is online.
public enum LatencyGrade: String, CaseIterable, Sendable {
    case good, fair, poor, silent
    public var title: String {
        switch self { case .good: return "良好"; case .fair: return "一般"; case .poor: return "较慢"; case .silent: return "无回复" }
    }
    public static func of(_ ms: Double?) -> LatencyGrade {
        guard let ms else { return .silent }
        return ms < 50 ? .good : ms < 150 ? .fair : .poor
    }
}

public struct LatencyStats: Sendable, Equatable {
    public let samples: Int
    public let replies: Int
    public let minimum: Double?
    public let average: Double?
    public let maximum: Double?
    /// Mean absolute difference between consecutive replies.
    public let jitter: Double?
    public var lossPercent: Int? { samples > 0 ? Int((Double(samples - replies) / Double(samples) * 100).rounded()) : nil }
}

/// In-memory history of one connection session; never persisted or exported.
public struct LatencyHistory: Sendable, Equatable {
    public static let capacity = 60
    public private(set) var session: String?
    public private(set) var series: [String: [LatencyPoint]] = [:]
    public init() {}

    public var isEmpty: Bool { series.isEmpty }
    public mutating func reset() { session = nil; series = [:] }

    /// A round from another session (reconnect, network switch) starts a new history.
    public mutating func record(_ round: LatencyRound, session: String) {
        if session != self.session { self.session = session; series = [:] }
        let at = fractionalTime.date(from: round.observedAt) ?? plainTime.date(from: round.observedAt)
        for sample in round.samples {
            let point: LatencyPoint
            switch sample.status {
            case "reply": point = LatencyPoint(ms: sample.latencyMS, at: at)
            case "timeout": point = LatencyPoint(ms: nil, at: at)
            default: continue
            }
            var points = series[sample.address, default: []]
            points.append(point)
            if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
            series[sample.address] = points
        }
    }

    public func points(for address: String) -> [LatencyPoint] { series[address] ?? [] }
    public func latest(for address: String) -> LatencyPoint? { series[address]?.last }

    public func stats(for address: String) -> LatencyStats {
        let points = points(for: address)
        let replies = points.compactMap(\.ms)
        var jitter: Double?
        if replies.count > 1 {
            jitter = zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1)
        }
        return LatencyStats(samples: points.count, replies: replies.count, minimum: replies.min(),
            average: replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count),
            maximum: replies.max(), jitter: jitter)
    }

    /// Latest point per address, graded; the median of the latest replies is the headline.
    public func summary(addresses: [String]) -> (median: Double?, grades: [LatencyGrade: Int]) {
        var grades: [LatencyGrade: Int] = [:]
        var replies: [Double] = []
        for address in addresses {
            guard let point = latest(for: address) else { continue }
            grades[LatencyGrade.of(point.ms), default: 0] += 1
            if let ms = point.ms { replies.append(ms) }
        }
        replies.sort()
        let median: Double? = replies.isEmpty ? nil
            : replies.count % 2 == 1 ? replies[replies.count / 2]
            : (replies[replies.count / 2 - 1] + replies[replies.count / 2]) / 2
        return (median, grades)
    }
}

/// Active (non-pending) peer addresses to sample, unique and bounded like the backend.
public enum LatencyTargets {
    public static let limit = 64
    public static func of(_ peers: [KnownPeer]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for peer in peers where !peer.pending {
            for address in peer.addresses where seen.insert(address).inserted {
                out.append(address)
                if out.count == limit { return out }
            }
        }
        return out
    }
}
