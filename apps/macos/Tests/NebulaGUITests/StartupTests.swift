import XCTest
import NebulaClient
@testable import NebulaGUI

/// Records calls instead of touching the system's login items.
@MainActor final class FakeLoginItem: LoginItemControl {
    var state = LoginItemState.disabled
    var needsApproval = false
    var failNext = false
    var settingsOpened = 0
    func register() throws {
        if failNext { failNext = false; throw BackendProblem(code: "register_failed", message: "Controlled failure") }
        state = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws { state = .disabled }
    func openSettings() { settingsOpened += 1 }
}

extension AppModelTests {
    private func startupModel(_ backend: ControlledBackend, defaults: UserDefaults, loginItem: FakeLoginItem? = nil) throws -> AppModel {
        let model = AppModel(client: backend, defaults: defaults, loginItem: loginItem ?? FakeLoginItem())
        model.profiles = [try profile("first"), try profile("second")]; model.selectedID = "second"
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true,"updateRequired":false}"#.utf8))
        return model
    }
    private func isolatedDefaults() -> UserDefaults {
        let name = "nebula-gui-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testLoginItemToggleFollowsTheSystemState() throws {
        let item = FakeLoginItem()
        let model = try startupModel(controlledBackend(), defaults: isolatedDefaults(), loginItem: item)
        XCTAssertEqual(model.loginItemState, .disabled)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemState, .enabled)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(model.loginItemState, .disabled)
        item.needsApproval = true
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemState, .requiresApproval)
        model.openLoginItemSettings()
        XCTAssertEqual(item.settingsOpened, 1)
        model.setLaunchAtLogin(false); item.failNext = true
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemState, .disabled)
        XCTAssertNotNil(model.loginItemNotice)
        // Approval granted in System Settings is picked up when the app becomes active.
        item.state = .enabled
        model.refreshLoginItem()
        XCTAssertEqual(model.loginItemState, .enabled)
    }

    /// Ad-hoc builds are a new, unregistered app to the system after every update (#67).
    func testLaunchAtLoginChoiceSurvivesANewBuildIdentity() throws {
        let defaults = isolatedDefaults()
        let oldBuild = FakeLoginItem()
        let first = try startupModel(controlledBackend(), defaults: defaults, loginItem: oldBuild)
        first.setLaunchAtLogin(true)
        XCTAssertEqual(oldBuild.state, .enabled)

        let newBuild = FakeLoginItem() // Same user, new cdhash: not registered.
        let updated = try startupModel(controlledBackend(), defaults: defaults, loginItem: newBuild)
        XCTAssertEqual(newBuild.state, .enabled, "the new build registers itself")
        XCTAssertEqual(updated.loginItemState, .enabled)
        XCTAssertNil(updated.loginItemNotice)

        let failing = FakeLoginItem(); failing.failNext = true
        let broken = try startupModel(controlledBackend(), defaults: defaults, loginItem: failing)
        XCTAssertEqual(broken.loginItemState, .disabled)
        XCTAssertNotNil(broken.loginItemNotice)

        updated.setLaunchAtLogin(false)
        let afterOff = FakeLoginItem()
        _ = try startupModel(controlledBackend(), defaults: defaults, loginItem: afterOff)
        XCTAssertEqual(afterOff.state, .disabled, "a choice to stay off is never overridden")
    }
    func testLaunchAtLoginMigratesFromTheSystemRecord() throws {
        let registered = FakeLoginItem(); registered.state = .enabled
        let defaults = isolatedDefaults()
        _ = try startupModel(controlledBackend(), defaults: defaults, loginItem: registered)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        let fresh = isolatedDefaults(), unregistered = FakeLoginItem()
        _ = try startupModel(controlledBackend(), defaults: fresh, loginItem: unregistered)
        XCTAssertNil(fresh.object(forKey: "launchAtLogin"), "no choice is invented for a never-registered app")
        XCTAssertEqual(unregistered.state, .disabled)
    }
    func testTestsAndPreviewsNeverTouchTheSystemLoginItem() {
        let model = AppModel(client: controlledBackend())
        XCTAssertEqual(model.loginItemState, .unavailable)
        model.setLaunchAtLogin(true)
        XCTAssertEqual(model.loginItemState, .unavailable)
        XCTAssertNotNil(model.loginItemNotice)
    }

    func testAutoConnectIsOptInRunsOnceAndNeverRequestsAuthorization() async throws {
        let defaults = isolatedDefaults()
        // A started tunnel records the network; only its ID is stored.
        let recorder = try startupModel(controlledBackend(), defaults: defaults)
        recorder.status = ConnectionStatus(state: "started", profileID: "first", error: nil, peers: [], startedAt: "t0")
        XCTAssertEqual(defaults.string(forKey: "lastConnectedProfileID"), "first")

        // Off by default: nothing is sent (ControlledBackend fails on any request).
        let off = try startupModel(controlledBackend(), defaults: defaults)
        XCTAssertFalse(off.autoConnect)
        await off.autoConnectIfNeeded()

        // Missing or outdated connection component: explain, never open the authorization review.
        defaults.set(true, forKey: "autoConnectAtLaunch")
        for json in [#"{"available":false}"#, #"{"available":true,"updateRequired":true}"#] {
            let model = try startupModel(controlledBackend(), defaults: defaults)
            model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(json.utf8))
            await model.autoConnectIfNeeded()
            XCTAssertEqual(model.problem?.code, "auto_connect_skipped")
            XCTAssertEqual(model.problem?.message, "连接后台未启用或需要升级，未自动连接。处理后可手动连接。")
            XCTAssertFalse(model.showAuthorizationReview)
        }
        // #115: a component newer than this App is not described as needing an upgrade.
        let newer = try startupModel(controlledBackend(), defaults: defaults)
        newer.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true,"updateRequired":true,"helperNewer":true}"#.utf8))
        await newer.autoConnectIfNeeded()
        XCTAssertEqual(newer.problem?.message, "连接后台来自较新的 Nebula，未自动连接。请更新 Nebula，或在配置页处理后手动连接。")
        XCTAssertFalse(newer.showAuthorizationReview)

        // A removed network is not replaced by another one.
        let removed = try startupModel(controlledBackend(), defaults: defaults)
        removed.profiles = [try profile("second")]
        await removed.autoConnectIfNeeded()
        XCTAssertEqual(removed.problem?.code, "auto_connect_skipped")

        // Already connected: nothing to do.
        let running = try startupModel(controlledBackend(), defaults: defaults)
        running.status = ConnectionStatus(state: "started", profileID: "second", error: nil, peers: [], startedAt: "t1")
        await running.autoConnectIfNeeded()

        // Healthy: selects and connects the last network once.
        let backend = controlledBackend()
        defaults.set("first", forKey: "lastConnectedProfileID")
        let model = try startupModel(backend, defaults: defaults)
        XCTAssertTrue(model.autoConnect)
        let connecting = backend.expect("connect")
        let task = Task { await model.autoConnectIfNeeded() }
        await fulfillment(of: [connecting], timeout: 2)
        XCTAssertEqual(backend.calls.last?.profileID, "first")
        XCTAssertEqual(model.selectedID, "first")
        try backend.replyJSON("connect", data: Data(#"{"state":"started","profileID":"first","peers":[],"startedAt":"t2"}"#.utf8))
        await task.value
        XCTAssertTrue(model.status.isStarted)
        model.status = .disconnected
        await model.autoConnectIfNeeded() // Once per launch.
        XCTAssertEqual(backend.calls.filter { $0.method == "connect" }.count, 1)
        _ = await model.shutdown()
    }
}
