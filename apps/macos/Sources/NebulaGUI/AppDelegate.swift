import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Set by the menu bar label; reopens the single main window after it was closed.
    var openMainWindow: (() -> Void)?
    private var cleaningUp = false
    /// Read before launch completes, while the opening Apple event is still current.
    private var launchedAsLoginItem = false
    private var hidOpeningWindow = false

    // The opening event may be current in either callback, so both are checked.
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = LaunchContext.launchedAsLoginItem(NSAppleEventManager.shared().currentAppleEvent)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = launchedAsLoginItem || LaunchContext.launchedAsLoginItem(NSAppleEventManager.shared().currentAppleEvent)
    }
    /// A login-item launch stays in the menu bar: the scene's opening window is closed once.
    /// Windows the user opens later from the menu bar are never affected.
    func mainWindowAppeared() {
        guard launchedAsLoginItem, !hidOpeningWindow else { return }
        hidOpeningWindow = true
        DispatchQueue.main.async {
            NSApp.windows.first { $0.isVisible && $0.title == "Nebula" }?.close()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !cleaningUp else { return .terminateLater }
        cleaningUp = true
        Task { @MainActor in
            let stopped = await model.shutdown()
            cleaningUp = false
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

extension AppModel {
    func quit() async {
        // End the calling Swift Task before entering AppKit's termination loop.
        // That loop must be able to run the MainActor task which cleans up.
        RunLoop.main.perform { NSApp.terminate(nil) }
    }
}
