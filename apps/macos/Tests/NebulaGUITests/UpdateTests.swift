import Foundation
import XCTest
import NebulaClient
@testable import NebulaGUI

/// Records update steps; never downloads, replaces an App or quits.
@MainActor final class FakeUpdater: SoftwareUpdating {
    var currentVersion = ReleaseVersion("0.1.0-rc1")
    var latestResult: Result<AvailableUpdate?, Error> = .success(nil)
    var prepareError: Error?
    var installError: Error?
    private(set) var steps: [String] = []
    func latest(after current: ReleaseVersion) async throws -> AvailableUpdate? { steps.append("latest \(current)"); return try latestResult.get() }
    func prepare(_ update: AvailableUpdate) async throws -> URL {
        steps.append("prepare \(update.version)")
        if let prepareError { throw prepareError }
        return URL(fileURLWithPath: "/staged/Nebula.app")
    }
    func install(_ staged: URL) throws { steps.append("install"); if let installError { throw installError } }
    func restart() { steps.append("restart") }
    func openPage(_ update: AvailableUpdate) { steps.append("open \(update.page.lastPathComponent)") }
}

extension AppModelTests {
    private func update(_ version: String = "0.1.0-rc2", installable: Bool = true) -> AvailableUpdate {
        let page = URL(string: "https://github.com/ChyiYaqing/nebula-gui/releases/tag/v\(version)")!
        let archive = URL(string: "https://github.com/ChyiYaqing/nebula-gui/releases/download/v\(version)/Nebula-v\(version)-macos-universal.zip")!
        return AvailableUpdate(version: ReleaseVersion(version)!, page: page, archive: archive,
                               signature: installable ? archive.appendingPathExtension("sig") : nil, archiveSize: 1000)
    }
    private func updateDefaults() -> UserDefaults {
        let name = "nebula-gui-update-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testUpdatesAreUnavailableWithoutAnUpdater() async throws {
        let model = AppModel(client: controlledBackend())
        XCTAssertFalse(model.updatesSupported)
        XCTAssertEqual(model.currentVersionText, "开发版本")
        await model.checkForUpdates()
        XCTAssertEqual(model.updateState, .idle)
    }

    func testCheckReportsAvailableUpToDateAndFailure() async throws {
        let updater = FakeUpdater()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let model = AppModel(client: controlledBackend(), now: { clock }, defaults: updateDefaults(), updater: updater)
        XCTAssertEqual(model.currentVersionText, "0.1.0-rc1")
        XCTAssertTrue(model.automaticUpdateChecks, "automatic checks default to on")

        await model.checkForUpdates()
        XCTAssertEqual(model.updateState, .upToDate)
        XCTAssertEqual(model.lastUpdateCheck, clock)

        updater.latestResult = .success(update())
        await model.checkForUpdates()
        XCTAssertEqual(model.updateState, .available(update()))
        XCTAssertEqual(model.availableUpdate, update())

        updater.latestResult = .failure(BackendProblem(code: "update_network", message: "offline"))
        clock += 60
        await model.checkForUpdates()
        XCTAssertEqual(model.updateState, .failed("offline", nil))
        XCTAssertEqual(model.lastUpdateCheck, clock - 60, "a failed check does not count as checked")
        XCTAssertEqual(model.problem, nil, "update failures never become connection problems")
        XCTAssertEqual(updater.steps, ["latest 0.1.0-rc1", "latest 0.1.0-rc1", "latest 0.1.0-rc1"])
    }

    func testAutomaticChecksRunOncePerDayAndCanBeTurnedOff() async throws {
        let updater = FakeUpdater(), defaults = updateDefaults()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let model = AppModel(client: controlledBackend(), now: { clock }, defaults: defaults, updater: updater)
        await model.checkForUpdatesIfDue()
        clock += 3600
        await model.checkForUpdatesIfDue()
        XCTAssertEqual(updater.steps.count, 1, "within a day of the last check")
        clock += 24 * 3600
        await model.checkForUpdatesIfDue()
        XCTAssertEqual(updater.steps.count, 2)

        model.automaticUpdateChecks = false
        clock += 48 * 3600
        await model.checkForUpdatesIfDue()
        XCTAssertEqual(updater.steps.count, 2)
        let relaunched = AppModel(client: controlledBackend(), defaults: defaults, updater: updater)
        XCTAssertFalse(relaunched.automaticUpdateChecks, "the choice survives a relaunch")
    }

    func testInstallPreparesReplacesThenRestarts() async throws {
        let updater = FakeUpdater(); updater.latestResult = .success(update())
        let model = AppModel(client: controlledBackend(), defaults: updateDefaults(), updater: updater)
        await model.checkForUpdates()
        await model.installUpdate()
        XCTAssertEqual(updater.steps, ["latest 0.1.0-rc1", "prepare 0.1.0-rc2", "install", "restart"])
        XCTAssertEqual(model.updateState, .installed(update()))
        await model.checkForUpdates()
        XCTAssertEqual(updater.steps.count, 4, "no new check while restarting")
    }

    func testFailedInstallLeavesTheAppAndKeepsTheReleasePage() async throws {
        let updater = FakeUpdater(); updater.latestResult = .success(update())
        updater.prepareError = BackendProblem(code: "update_signature_invalid", message: "bad signature")
        let model = AppModel(client: controlledBackend(), defaults: updateDefaults(), updater: updater)
        await model.checkForUpdates()
        await model.installUpdate()
        XCTAssertEqual(updater.steps, ["latest 0.1.0-rc1", "prepare 0.1.0-rc2"], "nothing is replaced after a failed check")
        XCTAssertEqual(model.updateState, .failed("bad signature", update()))
        model.openUpdatePage()
        XCTAssertEqual(updater.steps.last, "open v0.1.0-rc2")

        updater.prepareError = nil; updater.installError = BackendProblem(code: "update_replace_failed", message: "kept")
        await model.installUpdate()
        XCTAssertEqual(updater.steps.suffix(2), ["prepare 0.1.0-rc2", "install"])
        XCTAssertFalse(updater.steps.contains("restart"))
        XCTAssertEqual(model.updateState, .failed("kept", update()))
    }

    func testInstallWaitsForOtherOperationsAndNeedsASignedPackage() async throws {
        let updater = FakeUpdater(); updater.latestResult = .success(update(installable: false))
        let model = AppModel(client: controlledBackend(), defaults: updateDefaults(), updater: updater)
        await model.checkForUpdates()
        await model.installUpdate()
        XCTAssertEqual(updater.steps, ["latest 0.1.0-rc1"], "an unsigned release is only offered as a download page")

        updater.latestResult = .success(update())
        await model.checkForUpdates()
        model.busy = true
        await model.installUpdate()
        XCTAssertFalse(updater.steps.contains { $0.hasPrefix("prepare") })
        XCTAssertEqual(model.updateState, .failed("请等待当前操作完成后再安装更新。", update()))
    }
}
