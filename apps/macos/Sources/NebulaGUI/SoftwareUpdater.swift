import AppKit
import NebulaClient

/// Software update (#69). Only the App bundle is replaced; the root connection component
/// keeps its own user-approved upgrade flow.
@MainActor protocol SoftwareUpdating {
    var currentVersion: ReleaseVersion? { get }
    func latest(after current: ReleaseVersion) async throws -> AvailableUpdate?
    /// Downloads, verifies the signature, extracts and validates. Returns the staged App.
    func prepare(_ update: AvailableUpdate) async throws -> URL
    /// Replaces the running App with the staged one.
    func install(_ staged: URL) throws
    /// Quits (which disconnects) and reopens the App once this process has exited.
    func restart()
    func openPage(_ update: AvailableUpdate)
}

/// Anonymous, read-only requests to the public GitHub Releases API.
struct GitHubSoftwareUpdater: SoftwareUpdating {
    let bundle: URL
    let info: [String: Any]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    init(bundle: Bundle = .main) { self.bundle = bundle.bundleURL; info = bundle.infoDictionary ?? [:] }

    var currentVersion: ReleaseVersion? { (info["NebulaReleaseVersion"] as? String).flatMap { ReleaseVersion($0) } }
    private var userAgent: String { "NebulaGUI/\(currentVersion?.description ?? "unknown")" }

    func latest(after current: ReleaseVersion) async throws -> AvailableUpdate? {
        var request = URLRequest(url: UpdateCatalog.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await fetch(request, limit: 2 * 1024 * 1024)
        guard let releases = try? JSONDecoder().decode([UpdateRelease].self, from: data) else {
            throw BackendProblem(code: "update_check_failed", message: "无法读取发布信息，请稍后重试。")
        }
        return UpdateCatalog.newest(in: releases, current: current)
    }

    func prepare(_ update: AvailableUpdate) async throws -> URL {
        if let problem = UpdateInstaller.locationProblem(bundle) { throw problem }
        guard let archiveURL = update.archive, let signatureURL = update.signature else {
            throw BackendProblem(code: "update_not_installable", message: "此版本缺少签名的更新包，请从发布页手动下载。")
        }
        let key = info["NebulaUpdatePublicKey"] as? String ?? ""
        guard let identifier = info["CFBundleIdentifier"] as? String else {
            throw BackendProblem(code: "update_package_invalid", message: "无法确认当前 App 的标识。")
        }
        let signature = try await fetch(URLRequest(url: signatureURL), limit: 1024)
        let archive = try await fetch(URLRequest(url: archiveURL), limit: UpdateCatalog.maximumArchiveSize)
        try UpdateSignature.verify(archive, signature: signature, publicKey: key)
        let staging = try UpdateInstaller.stagingDirectory(for: bundle)
        do {
            let file = staging.appendingPathComponent("update.zip")
            try archive.write(to: file)
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            return try UpdatePackage.extract(file, into: unpacked, expected: update.version, bundleIdentifier: identifier)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func install(_ staged: URL) throws {
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        try UpdateInstaller.replace(bundle, with: staged)
    }

    /// A fixed script waits up to 60 s for this process to exit, then opens the App path.
    /// Both values are passed as arguments, never interpolated into the script.
    func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"i=0; while /bin/kill -0 "$1" 2>/dev/null && [ $i -lt 120 ]; do /bin/sleep 0.5; i=$((i+1)); done; /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$2""#,
                             "nebula-relaunch", String(getpid()), bundle.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    func openPage(_ update: AvailableUpdate) { NSWorkspace.shared.open(update.page) }

    private func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BackendProblem(code: "update_network", message: "无法连接 GitHub，请检查网络后重试。") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BackendProblem(code: "update_check_failed", message: status == 403 || status == 429 ? "GitHub 暂时限制了查询，请稍后再试。" : "发布信息暂不可用（HTTP \(status)）。")
        }
        guard data.count <= limit else { throw BackendProblem(code: "update_package_invalid", message: "下载内容超过大小上限，已放弃。") }
        return data
    }
}
