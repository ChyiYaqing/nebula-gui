import Charts
import SwiftUI
import NebulaClient

extension LatencyHealth {
    var title: String {
        switch self {
        case .stable: "稳定"
        case .unstable: "波动"
        case .lossy: "有丢包"
        case .silent: "未回复"
        }
    }
    var tint: Color {
        switch self {
        case .stable: Palette.accent
        case .unstable: .yellow
        case .lossy: .orange
        case .silent: .gray
        }
    }
    var symbol: String {
        switch self {
        case .stable: "checkmark.circle.fill"
        case .unstable: "waveform.path"
        case .lossy: "exclamationmark.circle.fill"
        case .silent: "questionmark.circle.fill"
        }
    }
}

func latencyText(_ ms: Double?) -> String {
    guard let ms else { return "—" }
    return ms < 10 ? String(format: "%.1f", ms) : String(format: "%.0f", ms)
}

/// Rounded status capsule, as used by Vitals beside its headline figure.
struct HealthPill: View {
    let health: LatencyHealth
    let text: String
    var body: some View {
        Label(text, systemImage: health.symbol)
            .font(.caption.weight(.semibold)).foregroundStyle(health.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(health.tint.opacity(0.14), in: Capsule())
    }
}

/// A compact curve with a gradient fill. Lost replies break the line and leave a mark on the baseline.
struct Sparkline: View {
    let values: [Double?]
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let replies = values.compactMap { $0 }
            if let low = replies.min(), let high = replies.max() {
                // A flat series stays near the middle instead of exaggerating sub-millisecond noise.
                let span = max(high - low, high * 0.25, 1)
                let base = max(0, low - span * 0.2), top = base + span * 1.4
                let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
                let point = { (index: Int, value: Double) in
                    CGPoint(x: values.count > 1 ? CGFloat(index) * step : size.width, y: size.height * (1 - CGFloat((value - base) / (top - base))))
                }
                let runs = Self.runs(values)
                ZStack {
                    ForEach(runs.indices, id: \.self) { run in
                        let indices = runs[run]
                        Path { path in
                            path.move(to: CGPoint(x: point(indices[0], values[indices[0]]!).x, y: size.height))
                            for index in indices { path.addLine(to: point(index, values[index]!)) }
                            path.addLine(to: CGPoint(x: point(indices[indices.count - 1], values[indices[indices.count - 1]]!).x, y: size.height))
                            path.closeSubpath()
                        }.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        Path { path in
                            path.move(to: point(indices[0], values[indices[0]]!))
                            for index in indices.dropFirst() { path.addLine(to: point(index, values[index]!)) }
                        }.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        if indices.count == 1 {
                            Circle().fill(tint).frame(width: 3, height: 3).position(point(indices[0], values[indices[0]]!))
                        }
                    }
                    ForEach(values.indices.filter { values[$0] == nil }, id: \.self) { index in
                        Rectangle().fill(Color.orange).frame(width: 2, height: 4)
                            .position(x: values.count > 1 ? CGFloat(index) * step : size.width, y: size.height - 2)
                    }
                }
            } else if !values.isEmpty {
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
    /// Index runs of consecutive replies.
    static func runs(_ values: [Double?]) -> [[Int]] {
        var runs: [[Int]] = [], current: [Int] = []
        for (index, value) in values.enumerated() {
            if value != nil { current.append(index) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

/// Network-wide summary at the top of the node page.
struct LatencySummaryCard: View {
    let history: LatencyHistory
    let targets: Int
    let note: String?
    private var measured: Int { history.points.count }
    private var worst: LatencyHealth? {
        [LatencyHealth.silent, .lossy, .unstable, .stable].first { history.count($0) > 0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latencyText(history.medianLatestMS)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("ms").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("中位延迟 · \(targets) 个活动地址").font(.caption).foregroundStyle(.secondary)
                        if let worst {
                            HealthPill(health: worst, text: worst == .stable ? "全部稳定" : "\(history.count(worst)) 个\(worst.title)")
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("中位延迟 \(latencyText(history.medianLatestMS)) 毫秒，\(targets) 个活动地址")
                Spacer(minLength: 12)
                Sparkline(values: history.medianSeries.map(\.replyMS), tint: Palette.accent)
                    .frame(width: 180, height: 46)
            }
            if measured > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(LatencyHealth.allCases.filter { history.count($0) > 0 }, id: \.self) { health in
                            Capsule().fill(health.tint)
                                .frame(width: max(4, (geometry.size.width - 9) * CGFloat(history.count(health)) / CGFloat(measured)))
                        }
                    }
                }.frame(height: 6).accessibilityHidden(true)
                VStack(spacing: 6) {
                    ForEach(LatencyHealth.allCases, id: \.self) { health in
                        HStack {
                            Circle().fill(health.tint).frame(width: 8, height: 8)
                            Text(health.title).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(history.count(health))").monospacedDigit().fontWeight(.medium)
                        }.font(.callout).accessibilityElement(children: .combine)
                    }
                }
            }
            Text(note ?? "每 5 秒向每个活动隧道发 1 个 ICMP 请求，只统计本次连接的最近 5 分钟。未回复可能是节点禁止 ICMP，不代表远端离线；待握手节点不探测。")
                .font(.caption).foregroundStyle(note == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Latest latency and a short curve, shown inside a node's address row.
struct LatencyBadge: View {
    let points: [LatencyPoint]
    let stats: LatencyStats
    var body: some View {
        HStack(spacing: 8) {
            Sparkline(values: points.map(\.replyMS), tint: stats.health.tint).frame(width: 72, height: 22)
            Text(stats.latest == nil ? "无回复" : latencyText(stats.latest) + " ms")
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(stats.latest == nil ? Color.orange : Color.primary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.latest == nil ? "最近一次未回复，\(stats.health.title)" : "延迟 \(latencyText(stats.latest)) 毫秒，\(stats.health.title)")
    }
}

/// Expanded detail for one address: the full five-minute curve and its statistics.
struct LatencyDetail: View {
    let points: [LatencyPoint]
    let stats: LatencyStats
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HealthPill(health: stats.health, text: stats.health.title)
                Spacer()
                Text("最近 \(stats.samples) 次 · 丢包 \(stats.lossPercent)%").foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(Sparkline.runs(points.map(\.replyMS)).enumerated()), id: \.offset) { run, indices in
                    ForEach(indices, id: \.self) { index in
                        AreaMark(x: .value("时间", points[index].time), y: .value("延迟", points[index].replyMS!), series: .value("段", run))
                            .foregroundStyle(LinearGradient(colors: [stats.health.tint.opacity(0.3), stats.health.tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("时间", points[index].time), y: .value("延迟", points[index].replyMS!), series: .value("段", run))
                            .foregroundStyle(stats.health.tint).interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                ForEach(points.indices.filter { points[$0].replyMS == nil }, id: \.self) { index in
                    RuleMark(x: .value("时间", points[index].time)).foregroundStyle(Color.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let ms = value.as(Double.self) { Text("\(latencyText(ms)) ms") } }
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute().second())
            } }
            .frame(height: 110)
            .accessibilityLabel("延迟曲线，虚线表示未回复")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    stat("最低", stats.minimum); stat("平均", stats.average); stat("最高", stats.maximum); stat("抖动", stats.jitter)
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Palette.small))
    }
    private func stat(_ title: String, _ ms: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(ms == nil ? "—" : latencyText(ms) + " ms").monospacedDigit().fontWeight(.medium)
        }.accessibilityElement(children: .combine)
    }
}
