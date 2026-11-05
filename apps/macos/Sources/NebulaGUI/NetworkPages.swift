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
            if model.status.profileID == profile.id {
                PeerListView(peers: model.status.peers, canProbe: model.isCurrentStarted && !model.busy, probeBusy: model.probeBusy,
                    copy: { model.copyNodeAddress($0) },
                    probe: { model.probeAddress = $0; Task { await model.testNode() } }).id(profile.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "连接后查看节点", symbol: "point.3.connected.trianglepath.dotted")
                    Text("此网络尚未连接。连接后会显示本机已知的隧道记录。")
                        .font(.callout).foregroundStyle(.secondary)
                }.nebulaSurface()
            }
            if model.isCurrentStarted {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "节点连通测试", symbol: "waveform.path.ecg")
                    HStack {
                        TextField("Nebula 节点 IP 地址", text: $model.probeAddress).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.testNode() } }
                            .accessibilityLabel("Nebula 节点 IP 地址")
                        if model.probeBusy { ProgressView().controlSize(.small) }
                        Button("测试节点") { Task { await model.testNode() } }
                            .frame(minHeight: 40)
                            .disabled(model.probeBusy || model.busy || model.probeAddress.isEmpty)
                    }
                    if let result = model.probeResult {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(result.address)：\(result.received)／\(result.sent) 回复")
                            Text("丢包 \(result.lossPercent.map { "\($0)%" } ?? "未测得")")
                            if let milliseconds = result.averageMS { Text(String(format: "平均往返 %.1f ms", milliseconds)) }
                            if result.received == 0 {
                                Text("未收到 ICMP 回复。节点可能禁止探测，请结合实际访问确认。").foregroundStyle(.secondary)
                            }
                            Text("测试于 " + eventTime(result.observedAt)).foregroundStyle(.secondary)
                        }.font(.caption).nebulaSurface()
                    }
                }
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
            VStack(alignment: .leading, spacing: 10) {
                Toggle("证书到期通知", isOn: Binding(get: { model.notificationsEnabled }, set: { enabled in Task { await model.setNotifications(enabled) } }))
                    .toggleStyle(.switch).font(.system(size: 13, weight: .medium)).disabled(model.notificationsBusy)
                Text(model.notificationText).font(.caption).foregroundStyle(.secondary)
            }
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
            DisclosureGroup("本次应用会话的连接事件") {
                if model.events.isEmpty { Text("暂无事件记录").foregroundStyle(.secondary) }
                ForEach(model.events.reversed()) { event in
                    HStack(alignment: .top) {
                        Text(event.title); Spacer(); Text(eventTime(event.time)).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            }.font(.caption)
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
