import AppKit
import SwiftUI
import NebulaClient

/// Menu bar panel tokens (#122): warm paper tiles, ink type, the app's single teal accent.
/// Dark appearance swaps to dark tiles; system fonts only.
enum Paper {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
    static let canvas = dynamic(0xE7E5E0, 0x161617)
    static let tile = dynamic(0xF8F7F4, 0x232325)
    static let ink = dynamic(0x141416, 0xF4F3F0)
    /// Darker than the reference's #8B887F so 11–12 pt captions keep 4.5:1 on the tile.
    static let muted = dynamic(0x6F6C64, 0x9A978F)
    static let wash = ink.opacity(0.05)
    static let track = ink.opacity(0.07)
    static let hair = ink.opacity(0.12)
    static let marker = ink.opacity(0.14)
    /// The connection tile when the tunnel is up: near-black with a teal glow top right.
    static let dark = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x15 / 255)
    static let glow = Color(red: 0.36, green: 0.80, blue: 0.67)
    static let darkText = Color(red: 0xF4 / 255, green: 0xF3 / 255, blue: 0xF0 / 255)
    static let darkMuted = darkText.opacity(0.6)
    static let radius: CGFloat = 20
    static let gap: CGFloat = 10
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Closes the MenuBarExtra panel through SwiftUI. Closing its window directly left
    /// SwiftUI believing the panel was open, so the status item stopped toggling it (#82).
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Tiles rise in, one after another, each time the panel opens.
    @State private var shown = false
    private var profile: NebulaClient.NetworkProfile? { model.menuProfile }
    private var presentation: ConnectionPresentation { ConnectionPresentation(model: model, profileID: profile?.id) }
    private var running: Bool { model.status.isStarted && model.status.profileID == profile?.id }
    /// Latency rows are limited so the panel stays short; the nodes page lists the rest.
    private static let nodeLimit = 6
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Paper.gap) {
                header.rise(0, shown)
                if let profile {
                    addressTile(profile).rise(1, shown)
                    HStack(alignment: .top, spacing: Paper.gap) {
                        nodesTile.rise(2, shown)
                        connectionTile.rise(3, shown)
                    }
                } else {
                    PaperTile {
                        TileLabel("开始")
                        Text("导入配置，把这台 Mac 加入你的网络。").font(.system(size: 13)).foregroundStyle(Paper.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }.rise(1, shown)
                }
                if model.canCancelConnection {
                    Button(role: .destructive) { Task { await model.disconnect() } } label: {
                        Label(model.connectionBusy ? "取消并断开" : "停止自动恢复", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }.buttonStyle(NebulaButtonStyle())
                }
                if let problem = model.problem ?? model.status.error { ProblemView(problem: problem) }
                if running { nodeSection.rise(4, shown) }
                if model.profiles.count > 1 { networkSection.rise(5, shown) }
                if case .available(let update) = model.updateState {
                    PaperTile(padding: 4) {
                        menuRow("新版本 \(update.version) 可用", symbol: "arrow.down.circle") { model.requestedPage = .configuration; showWindow() }
                    }.rise(6, shown)
                }
                toggles.padding(.horizontal, 6).padding(.top, 2)
            }.padding(12)
            footer
        }
        .frame(width: 340).background(Paper.canvas).tint(Palette.accent)
        .foregroundStyle(Paper.ink)
        .onAppear {
            model.showMenu(true)
            if reduceMotion { shown = true } else { DispatchQueue.main.async { shown = true } }
        }
        .onDisappear {
            model.showMenu(false)
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { shown = false }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NebulaMark().fill(Palette.accent).frame(width: 20, height: 20)
            Text("Nebula").font(.system(size: 14, weight: .semibold))
            Spacer()
            ConnectionStatusLabel(presentation: presentation)
        }.padding(.horizontal, 6).frame(minHeight: 28)
    }

    /// Network name, the local address in thin numerals, and how long the tunnel has been up.
    private func addressTile(_ profile: NebulaClient.NetworkProfile) -> some View {
        let address = profile.networks.first?.split(separator: "/").first.map(String.init) ?? "未提供"
        return PaperTile {
            HStack(alignment: .top) {
                TileLabel(profile.name)
                Spacer(minLength: 4)
                CopyAddressButton(address: address, label: "复制 Nebula IP") { model.copyNodeAddress(address) }
                    .id(profile.id)
                    .padding(.top, -12).padding(.trailing, -10)
            }
            Text(address).font(.system(size: 32, weight: .light)).tracking(-1.2).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true) // The duration line must not squeeze it.
                .padding(.top, -6)
                .accessibilityLabel("本机 Nebula IP \(address)")
            if running {
                // Refreshed twice a minute; the status poll does not change the duration text.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(connectedDuration(since: model.status.startedAt, now: context.date) ?? "隧道已启动")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.muted)
                }
            } else {
                Text(presentation.detail).font(.system(size: 12)).foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Active tunnels as a big number with the median latency; a dash when not connected.
    private var nodesTile: some View {
        let active = model.status.peers.filter { !$0.pending }.count
        let median = model.latency.summary(addresses: LatencyTargets.of(model.status.peers)).median
        let caption = !running ? "未连接" : active == 0 ? "暂无活动隧道" : median.map { "中位 \(latencyText($0))" } ?? "采样中"
        return PaperTile(height: 156) {
            TileLabel("活动节点")
            Spacer(minLength: 0)
            Text(running ? "\(active)" : "—").font(.system(size: 44, weight: .light)).tracking(-1.6).monospacedDigit()
                .foregroundStyle(running ? Paper.ink : Paper.muted)
            Text(caption).font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? "活动节点 \(active)，\(caption)" : "活动节点，未连接")
    }

    /// The tile turns dark with a teal glow while the tunnel is up; its switch connects or disconnects.
    private var connectionTile: some View {
        let words = ConnectionTileWords(model: model)
        let on = model.status.isStarted
        return PaperTile(height: 156) {
            TileLabel("连接", muted: on ? Paper.darkMuted : Paper.muted)
            Spacer(minLength: 0)
            Text(words.state).font(.system(size: 22, weight: .light)).tracking(-0.6)
                .foregroundStyle(on ? Paper.darkText : Paper.ink)
            Text(words.caption).font(.system(size: 11)).foregroundStyle(on ? Paper.darkMuted : Paper.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 8) {
                Toggle(model.menuActionTitle, isOn: Binding(get: { on }, set: { _ in toggleConnection() }))
                    .toggleStyle(PaperSwitchStyle(label: model.menuActionTitle, onDark: on))
                    .disabled(model.busy)
                if model.connectionBusy { ProgressView().controlSize(.small).environment(\.colorScheme, on ? .dark : colorScheme) }
            }.padding(.top, 4)
        } background: {
            ZStack {
                Paper.tile
                ZStack {
                    Paper.dark
                    RadialGradient(colors: [Paper.glow.opacity(0.5), .clear], center: UnitPoint(x: 0.8, y: 0.1), startRadius: 0, endRadius: 120)
                }.opacity(on ? 1 : 0)
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: on)
        }
    }

    /// Same path as the former full-width button: without the component the window opens to review it.
    private func toggleConnection() {
        if !model.status.isStarted && !model.authorization.available { showWindow() }
        Task { if model.status.isStarted { await model.disconnect() } else { await model.connectSelected() } }
    }

    private var nodeSection: some View {
        let peers = PeerQuery.matching(model.status.peers, text: "", filter: .active)
        return PaperTile {
            TileLabel("节点")
            if peers.isEmpty {
                Text("当前没有活动隧道。").font(.system(size: 12)).foregroundStyle(Paper.muted)
            }
            ForEach(Array(peers.prefix(Self.nodeLimit))) { peer in
                let address = peer.addresses.first ?? ""
                let points = model.latency.points(for: address)
                HStack(spacing: 8) {
                    Text(peer.name.isEmpty ? address : peer.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    LatencySparkline(points: points, color: lineGrade(points).color).frame(width: 56, height: 16)
                    Text(points.last.map { latencyText($0.ms) } ?? "采样中")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(points.last == nil ? Paper.muted : LatencyGrade.of(points.last?.ms ?? nil).color)
                        .frame(width: 56, alignment: .trailing)
                }
                .frame(minHeight: 24)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(peer.name) 延迟 \(points.last.map { latencyText($0.ms) } ?? "采样中")")
            }
            if peers.count > Self.nodeLimit {
                menuRow("查看全部 \(peers.count) 个节点…", symbol: "point.3.connected.trianglepath.dotted") {
                    model.requestedPage = .nodes; showWindow()
                }
            }
        }
    }

    /// Lists every network; picking another one switches to it (disconnecting the current one).
    private var networkSection: some View {
        PaperTile {
            TileLabel("切换网络")
            VStack(spacing: 0) {
                ForEach(model.profiles) { item in
                    let current = model.status.isStarted && model.status.profileID == item.id
                    Button {
                        Task { if await !model.switchNetwork(to: item.id) { showWindow() } }
                    } label: {
                        HStack(spacing: 10) {
                            // The current network's marker is the accent; the words say it too.
                            RoundedRectangle(cornerRadius: 2).fill(current ? Palette.accent : Paper.marker).frame(width: 3, height: 22)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if current { Text("当前").font(.system(size: 11)).foregroundStyle(Palette.accent) }
                            Spacer(minLength: 6)
                            Text(item.networks.first ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.muted).lineLimit(1)
                        }.font(.system(size: 13)).foregroundStyle(Paper.ink).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(model.busy || current)
                    .accessibilityLabel(current ? "\(item.name)，当前网络" : "切换到 \(item.name)")
                }
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            switchRow("登录时打开 Nebula", isOn: Binding(
                get: { model.loginItemState == .enabled || model.loginItemState == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }))
                .disabled(model.loginItemState == .unavailable)
            if model.loginItemState == .requiresApproval {
                Button("需要在系统设置中允许…") { model.openLoginItemSettings() }.buttonStyle(.link).font(.caption)
            }
            switchRow("启动后自动连接上次使用的网络", isOn: $model.autoConnect)
        }
    }
    /// Label on the left, switch aligned on the right edge like System Settings rows.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).toggleStyle(PaperSwitchStyle(label: title, small: true))
        }.frame(minHeight: 28)
    }

    /// Bottom toolbar like other menu bar apps: the main entry with a label on the left,
    /// compact icon actions with tooltips (and their shortcuts) on the right.
    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(help: "打开 Nebula 主窗口", accessibility: "打开 Nebula") { showWindow() } label: {
                Label("打开 Nebula", systemImage: "macwindow").font(.system(size: 12, weight: .medium))
            }
            Spacer(minLength: 8)
            FooterButton(help: "导入网络…（⌘O）", accessibility: "导入网络") { showWindow(); model.chooseImport() } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
            }.disabled(model.busy)
            FooterButton(help: "设置（⌘,）", accessibility: "设置") { model.requestedPage = .configuration; showWindow() } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            FooterButton(help: "断开并退出 Nebula（⌘Q）", accessibility: "断开并退出 Nebula") { Task { await model.quit() } } label: {
                Image(systemName: "power").font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(Paper.tile)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hair).frame(height: 1) }
    }

    /// Clicks outside the panel (other apps, their status items, the desktop, Nebula's
    /// own windows) already close it natively; actions that open the main window close it first.
    private func showWindow() { dismiss(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13)).foregroundStyle(Paper.ink)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}

/// The connection tile's words. The switch's own label is `menuActionTitle`, so state and action stay distinct.
struct ConnectionTileWords: Equatable {
    let state: String
    let caption: String
    @MainActor init(model: AppModel) {
        if model.connectionBusy { state = "处理中"; caption = "正在与连接后台同步" }
        else if model.status.isStarted { state = "已连接"; caption = "关闭开关即断开" }
        else if !model.authorization.available { state = "未连接"; caption = "需先启用连接后台" }
        else { state = "未连接"; caption = "打开开关即连接" }
    }
}

/// A paper tile: 20 pt radius, a hairline ring and a soft warm shadow.
private struct PaperTile<Content: View, Background: View>: View {
    var height: CGFloat?
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content
    @ViewBuilder let background: () -> Background
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Paper.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background { background().clipShape(shape) }
            .overlay { shape.strokeBorder(Paper.ink.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 1) }
            .shadow(color: Color(red: 40 / 255, green: 34 / 255, blue: 20 / 255).opacity(scheme == .dark ? 0 : 0.10), radius: 10, y: 6)
    }
}
private extension PaperTile where Background == Color {
    init(height: CGFloat? = nil, padding: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.init(height: height, padding: padding, content: content) { Paper.tile }
    }
}

/// Dot and word, top left of every tile.
private struct TileLabel: View {
    let text: String
    var muted: Color = Paper.muted
    init(_ text: String, muted: Color = Paper.muted) { self.text = text; self.muted = muted }
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
        }.accessibilityElement(children: .combine)
    }
}

/// A drawn switch: accent track when on, white knob sliding right. Still a Toggle, so keyboard
/// focus, Space and VoiceOver's on/off value come from the control itself.
private struct PaperSwitchStyle: ToggleStyle {
    /// macOS 13 cannot take the configuration's label view as an accessibility label.
    let label: String
    var small = false
    var onDark = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let width: CGFloat = small ? 34 : 46, height: CGFloat = small ? 20 : 26, inset: CGFloat = 2
        let knob = height - inset * 2
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Palette.accent : onDark ? Paper.darkText.opacity(0.2) : Paper.hair)
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .offset(x: configuration.isOn ? width - knob - inset : inset)
                }
                .animation(reduceMotion ? nil : .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.3), value: configuration.isOn)
                .frame(minWidth: 40, minHeight: small ? 28 : 40, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(configuration.isOn ? "开" : "关")
        .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// Rises 8 pt and fades in, tile i starting 40 ms after tile i − 1 (cubic out). Reduce Motion: no movement.
    func rise(_ index: Int, _ shown: Bool) -> some View {
        modifier(Rise(index: index, shown: shown))
    }
}
private struct Rise: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? nil : .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.3).delay(Double(index) * 0.04), value: shown)
    }
}

/// Toolbar button with a hover highlight; the whole rounded area is clickable.
private struct FooterButton<Content: View>: View {
    let help: String
    let accessibility: String
    let action: () -> Void
    @ViewBuilder let label: () -> Content
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(enabled ? Paper.ink : Paper.muted)
                .padding(.horizontal, 8).frame(minWidth: 32, minHeight: 30)
                .background(hovering && enabled ? Paper.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibility)
    }
}
