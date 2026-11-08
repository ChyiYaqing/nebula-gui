import SwiftUI
import NebulaClient

enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview, nodes, configuration, logs
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: return "概览"; case .nodes: return "节点"; case .configuration: return "配置"; case .logs: return "日志" }
    }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .nodes: return "point.3.connected.trianglepath.dotted"; case .configuration: return "slider.horizontal.3"; case .logs: return "list.bullet.rectangle" }
    }
    /// ⌘1…⌘4 follow the tab order.
    var shortcut: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }
}

/// A local view projection. Observed tunnel state and reachability remain distinct.
struct ConnectionPresentation {
    enum Tone { case neutral, connected, attention }
    let title: String
    let detail: String
    let symbol: String
    let tone: Tone
    var color: Color {
        switch tone { case .neutral: return .secondary; case .connected: return Palette.accent; case .attention: return .orange }
    }
    @MainActor init(model: AppModel, profileID: String?) {
        // Recovery and failure belong to one network; never attribute them to another selection.
        let recoveryOwner = model.recoveryProfileID, failureOwner = model.status.profileID
        func name(_ id: String) -> String { model.profiles.first { $0.id == id }?.name ?? "其他网络" }
        if model.connectionBusy {
            title = "正在处理连接"; detail = "正在与连接后台同步，请稍候。"; symbol = "arrow.triangle.2.circlepath"; tone = .neutral
        } else if model.status.isStarted && model.status.profileID == profileID {
            title = "隧道已启动"; detail = "节点是否可达以实际访问为准；节点页显示 ICMP 延迟。"; symbol = "checkmark.circle.fill"; tone = .connected
        } else if model.status.isStarted {
            title = "此网络未连接"; detail = "当前连接：\(model.active?.name ?? "其他网络")"; symbol = "arrow.triangle.swap"; tone = .neutral
        } else if !model.recoveryText.isEmpty, let owner = recoveryOwner, owner != profileID {
            title = "此网络未连接"; detail = "自动恢复：\(name(owner))"; symbol = "arrow.triangle.swap"; tone = .neutral
        } else if !model.recoveryText.isEmpty {
            title = "等待恢复"; detail = model.recoveryText; symbol = "arrow.clockwise.circle"; tone = .attention
        } else if model.status.state == "failed", let owner = failureOwner, owner != profileID {
            title = "此网络未连接"; detail = "连接未完成：\(name(owner))"; symbol = "arrow.triangle.swap"; tone = .neutral
        } else if model.status.state == "failed" {
            title = "连接未完成"; detail = "查看下方错误信息，必要时重试或清理连接。"; symbol = "exclamationmark.circle"; tone = .attention
        } else {
            title = model.profiles.isEmpty ? "等待导入" : "未连接"
            detail = "仅访问 Nebula 节点，不接管普通上网流量。"; symbol = "circle.dotted"; tone = .neutral
        }
    }
}

struct ConnectionStatusLabel: View {
    let presentation: ConnectionPresentation
    var body: some View {
        Label(presentation.title, systemImage: presentation.symbol)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(presentation.color)
            .accessibilityElement(children: .combine)
    }
}

enum MenuIconState: Equatable {
    case connected, connecting, attention, disconnected
    var accessibility: String {
        switch self {
        case .connected: return "Nebula 隧道已启动"
        case .connecting: return "Nebula 正在连接或恢复"
        case .attention: return "Nebula 需要处理"
        case .disconnected: return "Nebula 未连接"
        }
    }
}

/// "已连接 12 分钟" style duration since the tunnel started; nil when unknown.
func connectedDuration(since startedAt: String?, now: Date) -> String? {
    guard let startedAt else { return nil }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let start = fractional.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt) else { return nil }
    let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
    if minutes < 1 { return "刚刚连接" }
    if minutes < 60 { return "已连接 \(minutes) 分钟" }
    let hours = minutes / 60, rest = minutes % 60
    if hours < 24 { return rest == 0 ? "已连接 \(hours) 小时" : "已连接 \(hours) 小时 \(rest) 分钟" }
    return "已连接 \(hours / 24) 天 \(hours % 24) 小时"
}
