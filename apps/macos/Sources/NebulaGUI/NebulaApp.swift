import AppKit
import SwiftUI

@main struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Nebula", id: "main") {
            MainView(model: model).onAppear { delegate.model = model }
        }.defaultSize(width: 840, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入网络…") { model.chooseImport() }.keyboardShortcut("o") }
            CommandGroup(replacing: .appTermination) { Button("断开并退出 Nebula") { Task { await model.quit() } }.keyboardShortcut("q") }
        }
        MenuBarExtra("Nebula", systemImage: model.status.isStarted ? "network" : "point.3.connected.trianglepath.dotted") {
            MenuContent(model: model)
        }.menuBarExtraStyle(.window)
    }
}
