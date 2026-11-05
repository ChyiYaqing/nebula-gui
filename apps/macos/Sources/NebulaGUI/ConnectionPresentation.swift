import SwiftUI
import NebulaClient

enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview, nodes, configuration
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: return "概览"; case .nodes: return "节点"; case .configuration: return "配置" }
    }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .nodes: return "point.3.connected.trianglepath.dotted"; case .configuration: return "slider.horizontal.3" }
    }
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
        if model.connectionBusy {
            title = "正在处理连接"; detail = "正在与连接后台同步，请稍候。"; symbol = "arrow.triangle.2.circlepath"; tone = .neutral
        } else if model.status.isStarted && model.status.profileID == profileID {
            title = "隧道已启动"; detail = "节点是否可达，请通过实际访问或节点测试确认。"; symbol = "checkmark.circle.fill"; tone = .connected
        } else if model.status.isStarted {
            title = "此网络未连接"; detail = "当前连接：\(model.active?.name ?? "其他网络")"; symbol = "arrow.triangle.swap"; tone = .neutral
        } else if !model.recoveryText.isEmpty {
            title = "等待恢复"; detail = model.recoveryText; symbol = "arrow.clockwise.circle"; tone = .attention
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
