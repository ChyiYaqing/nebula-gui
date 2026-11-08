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
            XCTAssertFalse(model.showAuthorizationReview)
        }

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
