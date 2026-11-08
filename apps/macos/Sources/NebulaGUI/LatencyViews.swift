import SwiftUI
import NebulaClient

extension LatencyGrade {
    var color: Color {
        switch self { case .good: return Palette.accent; case .fair: return .orange; case .poor: return .red; case .silent: return .secondary }
    }
}

func latencyText(_ ms: Double?) -> String {
    guard let ms else { return "无回复" }
    return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
}

/// Fixed 60-slot timeline, newest at the right edge. Replies form the line with a
/// gradient fill; a missing reply breaks the line and marks the baseline.
struct LatencySparkline: View {
    let points: [LatencyPoint]
    var color: Color = Palette.accent
    var showsScale = false
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let top = max(points.compactMap(\.ms).max() ?? 1, 1)
            let step = size.width / CGFloat(LatencyHistory.capacity - 1)
            let start = CGFloat(LatencyHistory.capacity - points.count)
            let x = { (i: Int) in (start + CGFloat(i)) * step }
            let y = { (ms: Double) in size.height - 2 - CGFloat(ms / top) * (size.height - 4) }
            let runs = segments()
            ZStack(alignment: .topLeading) {
                ForEach(runs.indices, id: \.self) { r in
                    let run = runs[r]
                    Path { path in
                        path.move(to: CGPoint(x: x(run[0].0), y: size.height))
                        for (i, ms) in run { path.addLine(to: CGPoint(x: x(i), y: y(ms))) }
                        path.addLine(to: CGPoint(x: x(run[run.count - 1].0), y: size.height))
                        path.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: CGPoint(x: x(run[0].0), y: y(run[0].1)))
                        for (i, ms) in run.dropFirst() { path.addLine(to: CGPoint(x: x(i), y: y(ms))) }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if run.count == 1 { Circle().fill(color).frame(width: 3, height: 3).position(x: x(run[0].0), y: y(run[0].1)) }
                }
                ForEach(points.indices.filter { points[$0].ms == nil }, id: \.self) { i in
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3, height: 3).position(x: x(i), y: size.height - 1.5)
                }
                if showsScale {
                    Text(latencyText(top)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true) // The text beside it carries the value.
    }
    /// Consecutive replies, as (slot, ms) runs separated by missing replies.
    private func segments() -> [[(Int, Double)]] {
        var runs: [[(Int, Double)]] = [], current: [(Int, Double)] = []
        for (i, point) in points.enumerated() {
            if let ms = point.ms { current.append((i, ms)) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

struct LatencyDetail: View {
    let points: [LatencyPoint]
    let stats: LatencyStats
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LatencySparkline(points: points, color: LatencyGrade.of(points.last?.ms ?? nil).color, showsScale: true)
                .frame(height: 96)
                .background(alignment: .bottom) { Divider() }
            HStack(spacing: 18) {
                metric("最低", stats.minimum.map(latencyText) ?? "—")
                metric("平均", stats.average.map(latencyText) ?? "—")
                metric("最高", stats.maximum.map(latencyText) ?? "—")
                metric("抖动", stats.jitter.map(latencyText) ?? "—")
                metric("丢包", stats.lossPercent.map { "\($0)%" } ?? "—")
                metric("样本", "\(stats.samples)")
            }
            Text("最近 \(LatencyHistory.capacity) 次采样（约 5 分钟），只统计 ICMP 回复。未回复可能是节点禁止 ICMP，不代表远端离线。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.small))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }.accessibilityElement(children: .combine)
    }
}

/// Headline: median of each active address's latest reply, plus a grade breakdown.
struct LatencySummaryCard: View {
    let history: LatencyHistory
    let addresses: [String]
    var body: some View {
        let summary = history.summary(addresses: addresses)
        let total = summary.grades.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "节点延迟", symbol: "chart.xyaxis.line")
                Spacer()
                Text("每 5 秒采样 · 活动隧道 \(addresses.count) 个地址").foregroundStyle(.secondary)
            }
            if addresses.isEmpty {
                Text("当前没有活动隧道，暂无可监测的节点。待握手的节点不会被探测，以免触发握手。").foregroundStyle(.secondary)
            } else if total == 0 {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在采样…").foregroundStyle(.secondary) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(summary.median.map(latencyText) ?? "无回复")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                    let grade = LatencyGrade.of(summary.median)
                    Text(grade.title).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(grade.color).background(grade.color.opacity(0.14), in: Capsule())
                    Text("中位延迟").foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(LatencyGrade.allCases, id: \.self) { grade in
                            if let count = summary.grades[grade], count > 0 {
                                grade.color.opacity(grade == .silent ? 0.35 : 0.85)
                                    .frame(width: max(4, (geometry.size.width - 6) * CGFloat(count) / CGFloat(total)))
                            }
                        }
                    }.clipShape(Capsule())
                }.frame(height: 8)
                HStack(spacing: 14) {
                    ForEach(LatencyGrade.allCases, id: \.self) { grade in
                        HStack(spacing: 5) {
                            Circle().fill(grade.color).frame(width: 7, height: 7)
                            Text("\(grade.title) \(summary.grades[grade] ?? 0)")
                        }.accessibilityElement(children: .combine)
                    }
                    Spacer()
                }.foregroundStyle(.secondary)
                Text("良好 <50 ms，一般 <150 ms，较慢 ≥150 ms。只描述 ICMP 回复，不代表节点在线或离线。")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption).nebulaSurface()
    }
}
