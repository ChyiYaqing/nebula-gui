import AppKit
import SwiftUI
import NebulaClient
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: WorkspacePage
    @State private var dropTargeted = false
    init(model: AppModel, page: WorkspacePage = .overview) {
        self.model = model; _page = State(initialValue: page)
    }
    private var presentation: ConnectionPresentation {
        ConnectionPresentation(model: model, profileID: model.selectedID)
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let issue = model.problem ?? model.status.error { ProblemView(problem: issue) }
                        if let profile = model.selected {
                            if page != .configuration && (!model.authorization.available || model.authorization.updateRequired == true) {
                                AuthorizationStatusView(model: model)
                            }
                            switch page {
                            case .overview: NetworkOverview(model: model, profile: profile)
                            case .nodes: NetworkNodes(model: model, profile: profile)
                            case .configuration: NetworkConfiguration(model: model, profile: profile)
                            }
                        } else { emptyState }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Label("仅访问 Nebula 节点", systemImage: "lock.shield")
                    Spacer()
                    Button("导出诊断") { Task { await model.exportDiagnostics() } }.buttonStyle(.link)
                        .disabled(model.busy)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 40)
            }.background(Palette.canvas)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 570, idealHeight: 680)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Palette.large).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
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
            if CommandLine.arguments.contains("--show-details") { page = .configuration }
            model.showDetails = true
            snapshotIfRequested()
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                NebulaMark().fill(Palette.accent).frame(width: 28, height: 28)
                Text("Nebula").font(.system(size: 18, weight: .semibold))
            }.padding(.top, 8).accessibilityElement(children: .combine)
            Text("我的网络").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.profiles) { profile in
                        Button { model.selectedID = profile.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: model.status.isStarted && model.status.profileID == profile.id ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(model.status.isStarted && model.status.profileID == profile.id ? Palette.accent : .secondary)
                                    .font(.system(size: 12)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(profile.networks.first ?? "未提供地址").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedID == profile.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Palette.medium))
                        }.buttonStyle(PressStyle())
                            .accessibilityLabel("选择网络 \(profile.name)")
                            .accessibilityAddTraits(model.selectedID == profile.id ? .isSelected : [])
                    }
                }
            }
            Button { model.chooseImport() } label: {
                Label("导入网络", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 40)
            }.buttonStyle(.bordered).disabled(model.busy).keyboardShortcut("o", modifiers: .command)
            Text("本机验证版 · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发中")").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 200).background(Palette.sidebar)
    }
    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selected?.name ?? "连接你的网络").font(.system(size: 20, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(model.selected?.name ?? "Nebula")
                    ConnectionStatusLabel(presentation: presentation)
                }
                Spacer(minLength: 8)
                if model.connectionBusy { ProgressView().controlSize(.small).accessibilityLabel("正在处理连接") }
                if model.selected != nil {
                    NetworkActionButton(title: model.connectionActionTitle,
                        symbol: !model.authorization.available ? "lock.open" : model.status.isStarted ? "arrow.triangle.swap" : "power",
                        disconnecting: model.isCurrentStarted) { Task { await model.connectSelected() } }
                        .disabled(model.busy)
                }
            }.frame(minHeight: 52)
            if model.canCancelConnection || (model.status.profileID != nil && model.status.profileID != model.selectedID) || presentation.tone == .attention {
              HStack(alignment: .center, spacing: 8) {
                Text(presentation.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.canCancelConnection {
                    Button(role: .destructive) { Task { await model.disconnect() } } label: {
                        Label(model.connectionBusy ? "取消并断开" : "停止恢复", systemImage: "stop.circle")
                            .foregroundStyle(.red).frame(minHeight: 40)
                    }.buttonStyle(.bordered).tint(.red)
                } else if model.status.isStarted && !model.isCurrentStarted {
                    NetworkActionButton(title: "断开当前网络", symbol: "stop.circle", disconnecting: true) {
                        Task { await model.disconnect() }
                    }.disabled(model.busy)
                }
              }.frame(minHeight: 40)
            }
            if model.selected != nil { navigation }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }
    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(WorkspacePage.allCases) { item in
                Button { page = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                        .foregroundStyle(page == item ? Palette.accent : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(page == item ? Palette.accent.opacity(0.12) : .clear, in: Capsule())
                }.buttonStyle(PressStyle())
                    .keyboardShortcut(item == .overview ? "1" : item == .nodes ? "2" : "3", modifiers: .command)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .help("\(item.title)（⌘\(item == .overview ? "1" : item == .nodes ? "2" : "3")）")
            }
        }.padding(4).background(Palette.surface, in: Capsule())
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            NebulaMark().fill(Palette.accent).frame(width: 56, height: 56).accessibilityHidden(true)
            Text("从一份配置开始").font(.system(size: 26, weight: .medium))
            Text("导入管理员提供的文件，\n把这台 Mac 加入你的 Nebula 网络。")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                fileRow("config.yaml", description: "网络配置")
                fileRow("ca.cert", description: "CA 证书")
                fileRow("主机证书 + 主机密钥", description: "这台设备的身份")
            }.nebulaSurface()
            Button { model.chooseImport() } label: {
                Label("选择配置或文件夹", systemImage: "folder.badge.plus").padding(.horizontal, 10).frame(height: 40)
            }.buttonStyle(.borderedProminent).disabled(model.busy)
            Text("也可以直接拖入文件夹。原始文件不会被修改。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fileRow(_ name: String, description: String) -> some View {
        HStack {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(name).font(.system(size: 12, design: .monospaced))
            Spacer()
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
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
