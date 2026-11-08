import AppKit
import SwiftUI
import NebulaClient

struct NetworkOverview: View {
    @ObservedObject var model: AppModel
    let profile: NetworkProfile
    private var address: String { profile.networks.first?.split(separator: "/").first.map(String.init) ?? "未提供" }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "这台 Mac", symbol: "desktopcomputer")
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nebula IP").font(.caption).foregroundStyle(.secondary)
                        Text(address).font(.system(size: 26, weight: .medium, design: .monospaced))
                            .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.65)
                        Text(profile.device).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    CopyAddressButton(address: address, label: "复制 Nebula IP") { model.copyAddress() }
                        .id(profile.id)
                }
                if model.isCurrentStarted, let started = model.status.startedAt {
                    Label("连接开始于 " + eventTime(started), systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 170, alignment: .topLeading).nebulaSurface()
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "设备证书", symbol: "checkmark.shield")
                if let days = profile.daysRemaining {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(days < 0 ? "已过期" : days == 0 ? "不足 1" : String(days))
                            .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(days < 7 ? Color.orange : .primary)
                        if days >= 0 { Text("天后到期").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text(profile.expiration?.formatted(date: .abbreviated, time: .shortened) ?? profile.expiresAt)
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 170, alignment: .topLeading).nebulaSurface().frame(width: 170)
          }
            Text("隧道状态与远端可达性分别确认，可在节点页测试连接。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("连接中断后自动恢复", isOn: $model.automaticRecovery)
                    .toggleStyle(.switch).font(.system(size: 13, weight: .medium)).disabled(model.busy)
                Text("仅对本次主动建立的连接生效，主动断开后不会重连。")
                    .font(.caption).foregroundStyle(.secondary)
            }.nebulaSurface()
            if model.authorization.available && model.authorization.updateRequired != true {
                Label("连接后台已就绪", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "最近连接事件", symbol: "clock.arrow.circlepath")
                if model.events.isEmpty {
                    Text("本次应用会话暂无事件。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.events.suffix(5).reversed())) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title)
                            Spacer(minLength: 8)
                            Text(eventTime(event.time)).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }
        }
    }
}

struct NetworkNodes: View {
    @ObservedObject var model: AppModel
    let profile: NetworkProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isCurrentStarted {
                LatencySummaryCard(history: model.latency, addresses: LatencyTargets.of(model.status.peers))
            }
            if model.status.profileID == profile.id {
                PeerListView(peers: model.status.peers,
                    latency: model.latency, monitoring: model.isCurrentStarted, expanded: $model.latencyExpanded,
                    copy: { model.copyNodeAddress($0) }).id(profile.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "连接后查看节点", symbol: "point.3.connected.trianglepath.dotted")
                    Text("此网络尚未连接。连接后会显示本机已知的隧道记录。")
                        .font(.callout).foregroundStyle(.secondary)
                }.nebulaSurface()
            }
        }
    }
}

struct NetworkConfiguration: View {
    @ObservedObject var model: AppModel
    let profile: NetworkProfile
    private var locked: Bool { model.busy || model.status.profileID == profile.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(title: "网络身份", symbol: "person.crop.rectangle")
                    Spacer()
                    Button { model.chooseRename() } label: {
                        Label("重命名", systemImage: "pencil").frame(minHeight: 40)
                    }.disabled(model.busy).accessibilityLabel("重命名网络")
                }
                LabeledContent("网络名称", value: profile.name)
                LabeledContent("设备名称", value: profile.device)
                LabeledContent("网络地址", value: profile.networks.joined(separator: ", "))
                LabeledContent("有效期至", value: profile.expiration?.formatted(date: .abbreviated, time: .shortened) ?? profile.expiresAt)
                VStack(alignment: .leading, spacing: 6) {
                    Text("证书指纹").foregroundStyle(.secondary)
                    Text(profile.fingerprint).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.caption).nebulaSurface()
            StartupSettings(model: model)
            Divider()
            CertificateNotificationSettings(model: model)
            Divider()
            AuthorizationStatusView(model: model)
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "配置维护", symbol: "doc.badge.gearshape")
                Text(locked ? "请先断开此网络，再更新、恢复或移除配置。" : "更新保留上一版供恢复，原始分发文件保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("更新配置") { model.chooseImport(replacing: profile.id) }
                    Button("恢复上一版") { Task { await model.rollbackSelected() } }
                    Spacer(minLength: 8)
                    Button("移除网络…", role: .destructive) { Task { await model.removeSelected() } }.tint(.red)
                }.controlSize(.regular).frame(minHeight: 40).disabled(locked)
            }
        }
    }
}

/// Redacted kernel logs and structured backend events, both refreshed with the status poll.
struct NetworkLogs: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            KernelLogSection(model: model)
            eventSection
        }
    }
    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "连接事件", symbol: "list.bullet.rectangle")
                Spacer()
                Text("每 3 秒自动刷新").font(.caption).foregroundStyle(.secondary)
            }
            Text("后台本次运行期间最近 100 条结构化事件，最新在上。不含配置、密钥或节点地址。")
                .font(.caption).foregroundStyle(.secondary)
            if model.events.isEmpty {
                Text("暂无事件记录。连接、断开或导入网络后会在这里显示。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.events.reversed().enumerated()), id: \.offset) { index, event in
                        if index > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(eventTime(event.time)).foregroundStyle(.secondary)
                                .font(.system(size: 11, design: .monospaced))
                            Text(event.title).font(.system(size: 12))
                            Spacer(minLength: 8)
                            Text(event.code).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).textSelection(.enabled).accessibilityElement(children: .combine)
                    }
                }
            }
        }.nebulaSurface()
    }
}

/// Live tail: oldest first, newest at the bottom, following new entries unless paused.
struct KernelLogSection: View {
    @ObservedObject var model: AppModel
    @State private var follow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let bottom = "kernel-log-bottom"
    private var entries: [KernelLogEntry] { model.kernelLogs?.entries ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Nebula 内核日志", symbol: "terminal")
                Spacer()
                Toggle("自动滚动", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                    .help("开启时跟随最新日志；向上查看历史时可关闭")
                Button { copy() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .disabled(entries.isEmpty).frame(minHeight: 32)
            }
            Text("实时显示，每秒刷新，最新在底部。最近 300 条，仅在本机显示，不包含在诊断导出中；证书、数据包等字段不保存，只显示已隐藏的数量。")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = model.kernelLogNotice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider() }
                                row(entry)
                            }
                            Color.clear.frame(height: 1).id(Self.bottom)
                        }.padding(.trailing, 8)
                    }
                    .frame(height: 380)
                    .onAppear { if follow { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                    .onChange(of: entries.last?.id) { _ in
                        if follow { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                    }
                    .onChange(of: follow) { on in if on { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                }
            }
        }.nebulaSurface()
    }
    private func row(_ entry: KernelLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(eventTime(entry.time)).foregroundStyle(.secondary).font(.system(size: 11, design: .monospaced))
                Text(entry.level.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(entry.level)).frame(width: 44, alignment: .leading)
                Text(entry.message).font(.system(size: 12))
            }
            if !entry.fields.isEmpty || (entry.hidden ?? 0) > 0 {
                Text(entry.detail + ((entry.hidden ?? 0) > 0 ? "  （另有 \(entry.hidden ?? 0) 个字段已隐藏）" : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled).accessibilityElement(children: .combine)
    }
    private func color(_ level: String) -> Color {
        switch level { case "error": return .red; case "warn": return .orange; default: return .secondary }
    }
    private func copy() {
        let text = entries.map { "\($0.time) \($0.level.uppercased()) \($0.message) \($0.detail)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// App-wide startup behaviour (#63); both options default to off.
struct StartupSettings: View {
    @ObservedObject var model: AppModel
    private var loginText: String {
        switch model.loginItemState {
        case .enabled: return "登录 macOS 后在菜单栏启动，不弹出主窗口。"
        case .requiresApproval: return "已添加，但需要在系统设置的“登录项”中允许 Nebula。"
        case .disabled: return "关闭时需手动打开 Nebula。"
        case .unavailable: return "当前运行方式不支持设置登录项。"
        }
    }
    private var lastNetwork: String {
        guard let id = model.lastConnectedID else { return "尚未连接过网络。" }
        return model.profiles.first { $0.id == id }.map { "上次使用：\($0.name)。" } ?? "上次使用的网络已移除。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "启动与连接", symbol: "power")
            Toggle("登录时打开 Nebula", isOn: Binding(
                get: { model.loginItemState == .enabled || model.loginItemState == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
                .disabled(model.loginItemState == .unavailable)
            Text(model.loginItemNotice ?? loginText).font(.caption)
                .foregroundStyle(model.loginItemNotice != nil || model.loginItemState == .requiresApproval ? Color.orange : .secondary)
            if model.loginItemState == .requiresApproval {
                Button("打开登录项设置") { model.openLoginItemSettings() }.frame(minHeight: 40)
            }
            Toggle("启动后自动连接上次使用的网络", isOn: $model.autoConnect)
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            Text(lastNetwork + "不会自动请求管理员授权；连接失败时按“连接中断后自动恢复”重试。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CertificateNotificationSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("证书到期通知", isOn: Binding(get: { model.notificationsEnabled }, set: { enabled in Task { await model.setNotifications(enabled) } }))
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium)).disabled(model.notificationsBusy)
            Text(model.notificationText).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("发送测试通知") { Task { await model.sendTestNotification() } }
                    .frame(minHeight: 40).disabled(model.notificationsBusy)
                Button("打开系统设置") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                    .frame(minHeight: 40)
            }
            Text("App 运行时每 5 分钟及回到前台时补排提醒；退出后仅保留系统已安排的提醒。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AuthorizationStatusView: View {
    @ObservedObject var model: AppModel
    private var uncertain: Bool { model.status.isStarted && !model.authorization.available }
    private var title: String {
        uncertain ? "连接后台状态待确认" : model.authorization.updateRequired == true ? "连接后台可升级" : model.authorization.available ? "连接后台已启用" : "首次连接需要管理员授权"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: model.authorization.available ? "checkmark.shield" : "lock.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.authorization.available && model.authorization.updateRequired != true ? Palette.accent : .orange)
            Text(uncertain ? "上次确认隧道已启动，仍可从顶部断开，再检查后台状态。" : model.authorization.updateRequired == true ? "升级需要重启网络组件，请先断开连接。已保存配置会保留。" : model.authorization.available ? "网络组件负责隧道，GUI 以普通用户身份运行。" : "启用前会显示安装内容，再由 macOS 系统窗口请求管理员授权。")
                .font(.caption).foregroundStyle(.secondary)
            Button(model.authorization.updateRequired == true ? "升级后台" : model.authorization.available ? "管理后台" : "启用连接后台") {
                model.upgradingAuthorization = model.authorization.updateRequired == true
                model.removingAuthorization = model.authorization.available && !model.upgradingAuthorization
                model.showAuthorizationReview = true
            }.disabled(model.busy || model.status.isStarted).frame(minHeight: 40)
        }.nebulaSurface()
    }
}
