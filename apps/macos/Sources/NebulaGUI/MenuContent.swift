import AppKit
import SwiftUI
import NebulaClient

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private var profile: NebulaClient.NetworkProfile? { model.menuProfile }
    private var presentation: ConnectionPresentation { ConnectionPresentation(model: model, profileID: profile?.id) }
    /// Latency rows are limited so the panel stays short; the nodes page lists the rest.
    private static let nodeLimit = 6
    var body: some View {
        VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                NebulaMark().fill(Palette.accent).frame(width: 24, height: 24)
                Text("Nebula").font(.system(size: 15, weight: .semibold))
                Spacer()
                ConnectionStatusLabel(presentation: presentation)
            }
            if let profile {
                networkCard(profile)
                NetworkActionButton(title: model.menuActionTitle,
                    symbol: model.authorization.available ? "power" : "lock.open", disconnecting: model.status.isStarted, expands: true) {
                    if !model.status.isStarted && !model.authorization.available { showWindow() }
                    Task { if model.status.isStarted { await model.disconnect() } else { await model.connectSelected() } }
                }.disabled(model.busy)
            } else {
                Text("导入配置，把这台 Mac 加入你的网络。").font(.callout).foregroundStyle(.secondary)
            }
            if model.canCancelConnection {
                Button(role: .destructive) { Task { await model.disconnect() } } label: {
                    Label(model.connectionBusy ? "取消并断开" : "停止自动恢复", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(NebulaButtonStyle())
            }
            if let problem = model.problem ?? model.status.error { ProblemView(problem: problem) }
            if model.status.isStarted, model.status.profileID == profile?.id { nodeSection }
            if model.profiles.count > 1 { networkSection }
            if case .available(let update) = model.updateState {
                menuRow("新版本 \(update.version) 可用", symbol: "arrow.down.circle") { model.requestedPage = .configuration; showWindow() }
            }
            Divider()
            toggles
        }.padding(16)
        footer
        }
        .frame(width: 340).background(Palette.canvas).tint(Palette.accent)
        .background(MenuPanelDismissal())
        .onAppear { model.showMenu(true) }
        .onDisappear { model.showMenu(false) }
    }

    private func networkCard(_ profile: NebulaClient.NetworkProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            HStack {
                let address = profile.networks.first?.split(separator: "/").first.map(String.init) ?? "未提供"
                Text(address).font(.system(size: 13, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                CopyAddressButton(address: address, label: "复制 Nebula IP") { model.copyNodeAddress(address) }
                    .id(profile.id)
            }
            if model.status.isStarted && model.status.profileID == profile.id {
                // Refreshed twice a minute; the status poll does not change the duration text.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(summary(now: context.date)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(presentation.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.nebulaSurface()
    }
    private func summary(now: Date) -> String {
        let targets = LatencyTargets.of(model.status.peers)
        var parts = [connectedDuration(since: model.status.startedAt, now: now) ?? "隧道已启动"]
        parts.append("活动节点 \(model.status.peers.filter { !$0.pending }.count)")
        if let median = model.latency.summary(addresses: targets).median { parts.append("中位 \(latencyText(median))") }
        return parts.joined(separator: " · ")
    }

    private var nodeSection: some View {
        let peers = PeerQuery.matching(model.status.peers, text: "", filter: .active)
        return VStack(alignment: .leading, spacing: 4) {
            Text("节点").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if peers.isEmpty {
                Text("当前没有活动隧道。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(peers.prefix(Self.nodeLimit))) { peer in
                let address = peer.addresses.first ?? ""
                let points = model.latency.points(for: address)
                HStack(spacing: 8) {
                    Text(peer.name.isEmpty ? address : peer.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    LatencySparkline(points: points, color: lineGrade(points).color).frame(width: 64, height: 16)
                    Text(points.last.map { latencyText($0.ms) } ?? "采样中")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(points.last == nil ? Color.secondary : LatencyGrade.of(points.last?.ms ?? nil).color)
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
        VStack(alignment: .leading, spacing: 2) {
            Text("切换网络").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.profiles) { item in
                let current = model.status.isStarted && model.status.profileID == item.id
                Button {
                    Task { if await !model.switchNetwork(to: item.id) { showWindow() } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: current ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(current ? Palette.accent : .secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(item.networks.first ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy || current)
                .accessibilityLabel(current ? "\(item.name)，当前网络" : "切换到 \(item.name)")
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
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }.frame(minHeight: 24)
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
        .background(Palette.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func showWindow() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
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
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 8).frame(minWidth: 32, minHeight: 30)
                .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibility)
    }
}

/// Closes the menu bar panel when the user clicks elsewhere, like a system menu (#65):
/// a click in another app or on the desktop, or another Nebula window becoming key
/// (e.g. after "打开 Nebula" or "设置"). Clicks on the status item itself are left to
/// MenuBarExtra so the panel toggles instead of closing and reopening. Observers exist
/// only while the panel is on screen. Watching mouse clicks needs no Accessibility access.
private struct MenuPanelDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Watcher: NSView {
        private var mouseMonitor: Any?
        private var keyObserver: NSObjectProtocol?
        private var resignObserver: NSObjectProtocol?
        private var panelObservers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            panelObservers.forEach(NotificationCenter.default.removeObserver)
            panelObservers = []
            guard let panel = window else { return }
            // SwiftUI may reuse the panel window. A panel opened from the menu bar does not
            // always become key (e.g. while Nebula is inactive), so watching follows whether it
            // is actually on screen, not key status.
            panelObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.syncWithVisibility() }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.syncWithVisibility() }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.stopWatching() }
                },
            ]
            syncWithVisibility()
        }
        private func syncWithVisibility() {
            guard let panel = window else { return stopWatching() }
            if panel.isVisible && panel.occlusionState.contains(.visible) { startWatching() } else { stopWatching() }
        }
        private func startWatching() {
            guard mouseMonitor == nil, window != nil else { return }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                let other = note.object as? NSWindow
                Task { @MainActor in
                    guard let self, let other, other !== self.window, other.level == .normal else { return }
                    self.closePanel()
                }
            }
            // Another app becoming active (its window or its own menu bar item was clicked).
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
        }
        private func closePanel() {
            stopWatching()
            window?.close()
        }
        private func stopWatching() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            mouseMonitor = nil; keyObserver = nil; resignObserver = nil
        }
    }
}
