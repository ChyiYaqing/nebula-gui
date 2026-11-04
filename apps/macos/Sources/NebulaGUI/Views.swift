import AppKit
import SwiftUI
import NebulaClient
import UniformTypeIdentifiers

enum Palette {
    static let accent = Color(red: 0.08, green: 0.48, blue: 0.38)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20
}
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
/// Connection and interruption use distinct emphasis and symbols in every entry point.
private struct NetworkActionButton: View {
    let title: String
    let symbol: String
    let disconnecting: Bool
    let action: () -> Void
    var body: some View {
        if disconnecting {
            Button(role: .destructive, action: action) {
                Label(title, systemImage: "stop.circle").foregroundStyle(.red).frame(minWidth: 140, minHeight: 40)
            }.buttonStyle(.bordered).tint(.red)
        } else {
            Button(action: action) {
                Label(title, systemImage: symbol).frame(minWidth: 140, minHeight: 40)
            }.buttonStyle(.borderedProminent).tint(Palette.accent)
        }
    }
}
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(Palette.accent)
                    Text("NEBULA").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(2)
                }.padding(.top, 12)
                Text("我的网络").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.profiles) { profile in
                            Button { model.selectedID = profile.id } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(model.status.profileID == profile.id ? (model.status.isStarted ? Palette.accent : Color.orange) : Color.secondary.opacity(0.35)).frame(width: 7, height: 7).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        Text(profile.networks.first ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedID == profile.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Palette.small))
                            }.buttonStyle(PressStyle()).accessibilityLabel("选择网络 \(profile.name)")
                        }
                    }
                }
                Button { model.chooseImport() } label: { Label("导入网络", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 40) }
                    .buttonStyle(.bordered).disabled(model.busy).keyboardShortcut("o", modifiers: [.command])
                Text("本机验证版 · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发中")").font(.caption2).foregroundStyle(.secondary)
            }.padding(20).frame(width: 210).background(Palette.canvas)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(model.selected?.name ?? "连接你的网络").font(.system(size: 24, weight: .semibold)).tracking(-0.4)
                        if model.selected != nil {
                            Button { model.chooseRename() } label: { Image(systemName: "pencil").frame(width: 40, height: 40) }
                                .buttonStyle(.borderless).disabled(model.busy).help("重命名网络").accessibilityLabel("重命名网络")
                        }
                        Spacer()
                        Label(model.statusText, systemImage: model.status.isStarted ? "circle.fill" : "circle")
                            .font(.caption).foregroundStyle(model.status.isStarted ? Palette.accent : .secondary)
                    }
                    if let profile = model.selected {
                        authorizationPanel
                        connectionPanel(profile)
                        if let issue = model.problem ?? model.status.error { ProblemView(problem: issue) }
                        DisclosureGroup("身份与连接详情", isExpanded: $model.showDetails) { details(profile).padding(.top, 16) }
                        HStack {
                            Button("更新配置") { model.chooseImport(replacing: profile.id) }
                            Button("恢复上一版") { Task { await model.rollbackSelected() } }
                            Spacer()
                            Button("移除", role: .destructive) { Task { await model.removeSelected() } }
                        }.disabled(model.busy || model.status.profileID == profile.id)
                    } else {
                        emptyState
                        if let issue = model.problem { ProblemView(problem: issue) }
                    }
                    Spacer(minLength: 0)
                    Divider()
                    HStack(alignment: .top) {
                        Label("仅访问 Nebula 节点", systemImage: "lock.shield")
                        Spacer()
                        Button("导出诊断") { Task { await model.exportDiagnostics() } }.buttonStyle(.link)
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Palette.surface)
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 570, idealHeight: 650)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: Palette.large).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(8).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.replacementID = nil; await model.preview(path: url.path) }
            }
            return true
        }
        .sheet(isPresented: $model.importing) { ImportView(model: model) }
        .sheet(item: $model.renameTarget) { profile in RenameNetworkView(model: model, profile: profile) }
        .sheet(isPresented: $model.showAuthorizationReview) { AuthorizationReviewView(model: model) }
        .tint(Palette.accent)
        .onAppear {
            if CommandLine.arguments.contains("--show-details") { model.showDetails = true }
            snapshotIfRequested()
        }
    }
    private var authorizationPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.authorization.available ? "checkmark.shield" : "lock.shield")
                .foregroundStyle(model.authorization.available ? Palette.accent : .orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.authorization.updateRequired == true ? "连接后台可升级" : model.authorization.available ? "连接后台已启用" : "首次连接需要管理员授权").font(.callout.weight(.medium))
                Text(model.authorization.updateRequired == true ? "升级后可使用异常恢复和唤醒刷新，已保存配置保留。" : model.authorization.available ? "GUI 以普通用户运行，网络组件负责隧道。" : "点击启用，查看安装内容，再通过 macOS 系统窗口授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(model.authorization.updateRequired == true ? "升级后台" : model.authorization.available ? "管理后台" : "启用连接后台") {
                model.upgradingAuthorization = model.authorization.updateRequired == true
                model.removingAuthorization = model.authorization.available && !model.upgradingAuthorization
                model.showAuthorizationReview = true
            }.disabled(model.busy || model.status.isStarted)
        }.padding(14).background(Palette.canvas, in: RoundedRectangle(cornerRadius: Palette.medium))
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "network.badge.shield.half.filled").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("从一份配置开始").font(.system(size: 30, weight: .medium)).tracking(-0.6)
                Text("导入管理员提供的文件，\n把这台 Mac 加入你的 Nebula 网络。")
                    .font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                fileRow("config.yaml", description: "网络配置")
                fileRow("ca.cert", description: "CA 证书")
                fileRow("主机证书 + 主机密钥", description: "这台设备的身份")
            }.padding(.vertical, 8)
            Button { model.chooseImport() } label: {
                Label("选择配置或文件夹", systemImage: "folder.badge.plus").padding(.horizontal, 14).frame(height: 42)
            }.buttonStyle(.borderedProminent).disabled(model.busy)
            Text("也可以直接拖入文件夹。原始文件不会被修改。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 26).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fileRow(_ name: String, description: String) -> some View {
        HStack { Image(systemName: "doc").foregroundStyle(.secondary); Text(name).font(.system(size: 12, design: .monospaced)); Spacer(); Text(description).font(.caption).foregroundStyle(.secondary) }
    }
    private func connectionPanel(_ profile: NetworkProfile) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机 NEBULA IP").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    Text(profile.networks.first?.split(separator: "/").first.map(String.init) ?? "未提供")
                        .font(.system(size: 31, weight: .light, design: .monospaced)).textSelection(.enabled)
                    Text(profile.device).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.copyAddress() } label: { Image(systemName: "doc.on.doc").frame(width: 40, height: 40) }
                    .buttonStyle(.borderless).help("复制 Nebula IP").accessibilityLabel("复制 Nebula IP")
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                NetworkActionButton(
                    title: !model.authorization.available ? "启用连接后台" : model.isCurrentStarted ? "断开连接" : model.status.isStarted ? "切换并连接" : "连接网络",
                    symbol: !model.authorization.available ? "lock.open" : model.status.isStarted ? "arrow.triangle.swap" : "power",
                    disconnecting: model.isCurrentStarted
                ) { Task { await model.connectSelected() } }.disabled(model.busy)
                Spacer()
                if let days = profile.daysRemaining {
                    Label(days < 0 ? "证书已过期" : days == 0 ? "证书不足 1 天到期" : "证书剩余 \(days) 天", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(days < 7 ? Color.orange : .secondary)
                }
            }
            if model.canCancelConnection {
                HStack {
                    Text(model.recoveryText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { Task { await model.disconnect() } } label: {
                        Label(model.connectionBusy ? "取消并断开" : "停止自动恢复", systemImage: "stop.circle").foregroundStyle(.red)
                    }.buttonStyle(.bordered).tint(.red)
                }
            }
            Toggle("本次连接中断后自动恢复", isOn: $model.automaticRecovery)
                .toggleStyle(.checkbox).font(.caption).disabled(model.busy)
            Text(model.isCurrentStarted ? "隧道已启动。具体节点是否可达，需要实际访问确认。" : "连接后仅处理 Nebula 网络流量。")
                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 28, alignment: .topLeading)
        }.padding(24).background(Palette.canvas, in: RoundedRectangle(cornerRadius: Palette.large))
    }
    private func details(_ profile: NetworkProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.status.profileID == profile.id, let started = model.status.startedAt { LabeledContent("连接开始", value: eventTime(started)) }
            LabeledContent("设备名称", value: profile.device)
            LabeledContent("网络地址", value: profile.networks.joined(separator: ", "))
            LabeledContent("有效期至", value: profile.expiration?.formatted(date: .abbreviated, time: .shortened) ?? profile.expiresAt)
            VStack(alignment: .leading, spacing: 6) {
                Text("证书指纹").foregroundStyle(.secondary)
                Text(profile.fingerprint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            Divider()
            DisclosureGroup("连接事件（应用会话）") {
                if model.events.isEmpty { Text("暂无事件记录").foregroundStyle(.secondary) }
                ForEach(model.events.reversed()) { event in
                    HStack(alignment: .top) { Text(event.title); Spacer(); Text(eventTime(event.time)).foregroundStyle(.secondary) }
                        .padding(.vertical, 3)
                }
            }
            Divider()
            Toggle("证书到期通知", isOn: Binding(get: { model.notificationsEnabled }, set: { enabled in Task { await model.setNotifications(enabled) } }))
                .toggleStyle(.checkbox).disabled(model.notificationsBusy)
            Text(model.notificationText).foregroundStyle(.secondary)
            Divider()
            if model.status.profileID != profile.id {
                Text("此网络当前未连接。").font(.caption).foregroundStyle(.secondary)
            } else {
                PeerListView(peers: model.status.peers, canProbe: model.isCurrentStarted && !model.busy, probeBusy: model.probeBusy,
                    copy: { model.copyNodeAddress($0) }, probe: { address in model.probeAddress = address; Task { await model.testNode() } })
                    .id(profile.id)
            }
            if model.isCurrentStarted {
                Divider()
                Text("节点连通测试").font(.subheadline.weight(.medium))
                HStack {
                    TextField("Nebula 节点 IP 地址", text: $model.probeAddress).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.testNode() } }
                    if model.probeBusy { ProgressView().controlSize(.small) }
                    Button("测试节点") { Task { await model.testNode() } }
                        .disabled(model.probeBusy || model.busy || model.probeAddress.isEmpty)
                }
                if let result = model.probeResult {
                    Text("\(result.address)：\(result.received)／\(result.sent) 回复，丢包 \(result.lossPercent.map { "\($0)%" } ?? "未测得")")
                    if let milliseconds = result.averageMS { Text(String(format: "平均往返 %.1f ms", milliseconds)) }
                    if result.received == 0 { Text("未收到 ICMP 回复。节点可能禁止探测，请结合实际访问确认。").foregroundStyle(.secondary) }
                    Text("测试于 " + eventTime(result.observedAt)).foregroundStyle(.secondary)
                }
            }
        }.font(.caption)
    }
    private func eventTime(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw))?.formatted(date: .abbreviated, time: .standard) ?? raw
    }
    private func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot-to"), index + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let view = NSApp.windows.first(where: { $0.title == "Nebula" })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        }
    }
}
struct ProblemView: View {
    let problem: BackendProblem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(problem.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let field = problem.field { Text(field).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Palette.small))
        .accessibilityElement(children: .combine)
    }
}
struct ImportView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.replacementID == nil ? "检查并导入网络" : "更新网络配置").font(.title2.weight(.semibold))
            if model.busy { ProgressView("正在验证配置与设备身份…").padding(.vertical) }
            if let candidate = model.candidate {
                TextField("网络名称", text: $model.importName).textFieldStyle(.roundedBorder)
                if let message = ProfileNameRules.validationMessage(model.importName) { Text(message).font(.caption).foregroundStyle(.orange) }
                LabeledContent("设备", value: candidate.device)
                LabeledContent("Nebula 地址", value: candidate.networks.joined(separator: ", "))
                LabeledContent("有效期至", value: candidate.expiration?.formatted(date: .abbreviated, time: .omitted) ?? candidate.expiresAt)
                Label("配置、证书与密钥校验通过", systemImage: "checkmark.shield").foregroundStyle(Palette.accent)
                Text("保存独立副本，原始文件保持不变。更新配置会保留上一版供恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = model.problem {
                ProblemView(problem: issue)
                if issue.code == "missing_file", ["pki.ca", "pki.cert", "pki.key"].contains(issue.field ?? "") {
                    Button("补选对应文件") { model.supplementFile() }
                }
            }
            HStack {
                Button("取消") { model.importing = false; model.candidate = nil; model.problem = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.replacementID == nil ? "保存网络" : "确认更新") { Task { await model.confirmImport() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.candidate == nil || ProfileNameRules.validationMessage(model.importName) != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 480).tint(Palette.accent).interactiveDismissDisabled(model.busy)
    }
}
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Nebula").font(.headline); Spacer(); Text(model.statusText).font(.caption).foregroundStyle(.secondary) }
            if let active = model.active ?? model.selected {
                Text(active.name).font(.subheadline)
                Text(active.networks.first ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                NetworkActionButton(
                    title: !model.authorization.available ? "启用连接后台" : model.status.isStarted ? "断开连接" : "连接所选网络",
                    symbol: model.authorization.available ? "power" : "lock.open",
                    disconnecting: model.status.isStarted
                ) {
                    if !model.authorization.available { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    Task { if model.status.isStarted { await model.disconnect() } else { await model.connectSelected() } }
                }.disabled(model.busy)
            }
            Divider()
            Button("打开 Nebula") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("导入网络…") { openWindow(id: "main"); model.chooseImport() }.disabled(model.busy)
            Button("断开并退出") { Task { await model.quit() } }
        }.padding(18).frame(width: 280).tint(Palette.accent)
    }
}

struct AuthorizationReviewView: View {
    @ObservedObject var model: AppModel
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.removingAuthorization ? "移除连接后台" : model.upgradingAuthorization ? "升级连接后台" : "启用连接后台", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text(model.removingAuthorization ? "将停止并移除 Nebula GUI 的网络组件。原始配置与应用保存的网络不会删除。" : model.upgradingAuthorization ? "将重启并升级本应用的网络组件，现有受管连接会中断。失败时尝试恢复旧组件；已保存的配置保留。" : "安装仅供当前登录用户控制的 root 网络组件。GUI 保持普通用户身份，管理员密码仅在 macOS 系统窗口输入。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("将写入／移除以下文件").font(.caption.weight(.semibold))
                Text(AuthorizationPlan.helperPath).textSelection(.enabled)
                Text(AuthorizationPlan.plistPath).textSelection(.enabled)
            }.font(.system(size: 11, design: .monospaced)).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if !model.removingAuthorization {
                Text("组件开机启动，但不会自动连接。只接受当前用户的连接、断开和查询请求；GUI 后台退出即清理隧道。旧 Nebula 服务若仍加载，安装会被拒绝。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(model.removingAuthorization ? "我同意停止并移除此组件" : model.upgradingAuthorization ? "我同意重启并升级上述网络组件" : "我同意安装上述网络组件并授予系统权限", isOn: $consent)
                .toggleStyle(.checkbox)
            HStack {
                Button("取消") { model.showAuthorizationReview = false }.keyboardShortcut(.cancelAction)
                if !model.removingAuthorization {
                    Button("移除已有组件…") { model.removingAuthorization = true; model.upgradingAuthorization = false; consent = false }
                }
                Spacer()
                Button(model.removingAuthorization ? "授权移除" : model.upgradingAuthorization ? "授权升级" : "授权安装") {
                    Task { await model.manageAuthorization(removing: model.removingAuthorization) }
                }.buttonStyle(.borderedProminent).disabled(!consent || model.busy)
            }
        }.padding(28).frame(width: 570).tint(Palette.accent).interactiveDismissDisabled(model.busy)
    }
}
