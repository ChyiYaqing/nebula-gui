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

/// Serves fixed responses by URL and records each request with its Accept header (#74).
final class StubDownloads: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloads.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        Self.requests.append(url + " " + (request.value(forHTTPHeaderField: "Accept") ?? "-"))
        guard let (status, body) = Self.responses[url] else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdateDownloadTests: XCTestCase {
    private let page = URL(string: "https://github.com/ChyiYaqing/nebula-gui/releases/download/v0.1.0-rc3/Nebula-v0.1.0-rc3-macos-universal.zip.sig")!
    private let api = URL(string: "https://api.github.com/repos/ChyiYaqing/nebula-gui/releases/assets/726273122")!
    override func setUp() { StubDownloads.responses = [:]; StubDownloads.requests = [] }

    @MainActor private func download(fallback: URL?, limit: Int = 1024) async throws -> Data {
        try await GitHubSoftwareUpdater(session: StubDownloads.session()).download(page, fallback: fallback, limit: limit)
    }

    @MainActor func testFailedDownloadRetriesOnceThroughTheAPI() async throws {
        StubDownloads.responses = [page.absoluteString: (504, Data("gateway".utf8)), api.absoluteString: (200, Data("signature".utf8))]
        let data = try await download(fallback: api)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "signature")
        XCTAssertEqual(StubDownloads.requests, [page.absoluteString + " -", api.absoluteString + " application/octet-stream"])
    }

    @MainActor func testDownloadUsesThePageAddressWhenItWorks() async throws {
        StubDownloads.responses = [page.absoluteString: (200, Data("signature".utf8))]
        _ = try await download(fallback: api)
        XCTAssertEqual(StubDownloads.requests, [page.absoluteString + " -"])
    }

    @MainActor func testFailedDownloadsReportADownloadProblem() async throws {
        StubDownloads.responses = [page.absoluteString: (504, Data()), api.absoluteString: (502, Data())]
        do { _ = try await download(fallback: api); XCTFail("both addresses failed") }
        catch let problem as BackendProblem {
            XCTAssertEqual(problem.code, "update_download_failed")
            XCTAssertEqual(problem.message, "下载更新包失败（HTTP 502），请稍后重试，或从发布页手动下载。")
        }
        StubDownloads.requests = []
        do { _ = try await download(fallback: nil); XCTFail("no fallback") }
        catch let problem as BackendProblem { XCTAssertEqual(problem.message, "下载更新包失败（HTTP 504），请稍后重试，或从发布页手动下载。") }
        XCTAssertEqual(StubDownloads.requests.count, 1)
        StubDownloads.responses = [:]
        do { _ = try await download(fallback: nil); XCTFail("offline") }
        catch let problem as BackendProblem { XCTAssertEqual(problem.code, "update_download_failed"); XCTAssertTrue(problem.message.hasPrefix("下载更新包时无法连接 GitHub")) }
    }

    @MainActor func testOversizedDownloadIsNotRetried() async throws {
        StubDownloads.responses = [page.absoluteString: (200, Data(count: 2048)), api.absoluteString: (200, Data("small".utf8))]
        do { _ = try await download(fallback: api); XCTFail("over the limit") }
        catch let problem as BackendProblem { XCTAssertEqual(problem.code, "update_package_invalid") }
        XCTAssertEqual(StubDownloads.requests.count, 1)
    }
}
