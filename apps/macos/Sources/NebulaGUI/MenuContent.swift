import AppKit
import SwiftUI
import NebulaClient

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private var profile: NebulaClient.NetworkProfile? { model.active ?? model.selected }
    private var presentation: ConnectionPresentation { ConnectionPresentation(model: model, profileID: profile?.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                NebulaMark().fill(Palette.accent).frame(width: 24, height: 24)
                Text("Nebula").font(.system(size: 15, weight: .semibold))
                Spacer()
                ConnectionStatusLabel(presentation: presentation)
            }
            if let profile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack {
                        let address = profile.networks.first?.split(separator: "/").first.map(String.init) ?? "未提供"
                        Text(address).font(.system(size: 13, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        CopyAddressButton(address: address, label: "复制 Nebula IP") { model.copyNodeAddress(address) }
                            .id(profile.id)
                    }
                    Text(presentation.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.nebulaSurface()
                NetworkActionButton(title: model.menuActionTitle,
                    symbol: model.authorization.available ? "power" : "lock.open", disconnecting: model.status.isStarted) {
                    if !model.status.isStarted && !model.authorization.available { showWindow() }
                    Task { if model.status.isStarted { await model.disconnect() } else { await model.connectSelected() } }
                }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("导入配置，把这台 Mac 加入你的网络。").font(.callout).foregroundStyle(.secondary)
            }
            if model.canCancelConnection {
                Button(role: .destructive) { Task { await model.disconnect() } } label: {
                    Label(model.connectionBusy ? "取消并断开" : "停止自动恢复", systemImage: "stop.circle")
                        .foregroundStyle(.red).frame(minHeight: 40)
                }.buttonStyle(.bordered).tint(.red)
            }
            if let problem = model.problem ?? model.status.error { ProblemView(problem: problem) }
            Divider()
            VStack(spacing: 2) {
                menuRow("打开 Nebula", symbol: "macwindow") { showWindow() }
                menuRow("导入网络…", symbol: "plus.circle") { showWindow(); model.chooseImport() }.disabled(model.busy)
                menuRow("断开并退出", symbol: "power") { Task { await model.quit() } }
            }
        }.padding(18).frame(width: 320).background(Palette.canvas).tint(Palette.accent)
    }
    private func showWindow() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}
