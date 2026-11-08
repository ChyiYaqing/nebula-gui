import AppKit
import SwiftUI

@main struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Nebula", id: "main") {
            MainView(model: model).onAppear { delegate.model = model; delegate.mainWindowAppeared() }
        }.defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入网络…") { model.chooseImport() }.keyboardShortcut("o") }
            CommandGroup(replacing: .appTermination) { Button("断开并退出 Nebula") { Task { await model.quit() } }.keyboardShortcut("q") }
        }
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // The status item lives for the whole app session, unlike the closable main window.
            MenuBarLabel(connected: model.status.isStarted) { delegate.openMainWindow = $0 }
        }.menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let connected: Bool
    let register: (@escaping () -> Void) -> Void
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(nsImage: NebulaGlyph.image(size: 20, connected: connected))
            .accessibilityLabel(connected ? "Nebula 隧道已启动" : "Nebula 未连接")
            .onAppear { let open = openWindow; register { open(id: "main") } }
    }
}
