import AppKit
import SwiftUI

@main struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Nebula", id: "main") {
            MainView(model: model).onAppear { delegate.model = model }
        }.defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入网络…") { model.chooseImport() }.keyboardShortcut("o") }
            CommandGroup(replacing: .appTermination) { Button("断开并退出 Nebula") { Task { await model.quit() } }.keyboardShortcut("q") }
        }
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: NebulaGlyph.image(size: 20, connected: model.status.isStarted))
                .accessibilityLabel(model.status.isStarted ? "Nebula 隧道已启动" : "Nebula 未连接")
        }.menuBarExtraStyle(.window)
    }
}
