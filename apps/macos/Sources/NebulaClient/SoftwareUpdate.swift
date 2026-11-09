import CryptoKit
import Foundation

/// App release number as in VERSION: `X.Y.Z` or `X.Y.Z-rcN`, without leading zeros (#69).
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    /// Release candidate number; nil for a final release.
    public let candidate: Int?
    public var isPrerelease: Bool { candidate != nil }
    public var description: String { "\(major).\(minor).\(patch)" + (candidate.map { "-rc\($0)" } ?? "") }

    public init?(_ text: String) {
        let pattern = #"^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})(?:-rc([1-9][0-9]{0,5}))?$"#
        guard let match = text.range(of: pattern, options: .regularExpression), match == text.startIndex..<text.endIndex else { return nil }
        let main = text.split(separator: "-", maxSplits: 1)
        let numbers = main[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
        candidate = main.count == 2 ? Int(main[1].dropFirst(2)) : nil
    }
    /// A release tag is the version with a `v` prefix.
    public init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // 0.1.0-rc1 < 0.1.0-rc2 < 0.1.0
        switch (lhs.candidate, rhs.candidate) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        default: return false
        }
    }
}

/// The fields Nebula reads from the GitHub Releases API.
public struct UpdateRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int
        public let browserDownloadURL: URL
        /// The same asset through the API; downloads with `Accept: application/octet-stream` (#74).
        public let apiURL: URL?
        enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url", apiURL = "url" }
    }
    public let tagName: String
    public let draft: Bool
    public let htmlURL: URL
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, htmlURL = "html_url", assets }
}

/// A newer release. Without both archive and signature it can only be downloaded by hand.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: ReleaseVersion
    public let page: URL
    public let archive: URL?
    public let signature: URL?
    public let archiveSize: Int
    /// API addresses of the same files, tried when the github.com download fails (#74).
    public let archiveAPI: URL?
    public let signatureAPI: URL?
    public var installable: Bool { archive != nil && signature != nil }
    public init(version: ReleaseVersion, page: URL, archive: URL?, signature: URL?, archiveSize: Int,
                archiveAPI: URL? = nil, signatureAPI: URL? = nil) {
        self.version = version; self.page = page; self.archive = archive; self.signature = signature; self.archiveSize = archiveSize
        self.archiveAPI = archiveAPI; self.signatureAPI = signatureAPI
    }
}

public enum UpdateCatalog {
    public static let releasesURL = URL(string: "https://api.github.com/repos/ChyiYaqing/nebula-gui/releases?per_page=30")!
    public static let maximumArchiveSize = 200 * 1024 * 1024

    public static func archiveName(_ version: ReleaseVersion) -> String { "Nebula-v\(version)-macos-universal.zip" }

    /// The highest published version above `current`. A final release is only offered
    /// other final releases; a release candidate is also offered newer candidates.
    /// The version number decides, not GitHub's prerelease flag: ad-hoc final builds are
    /// also published as prereleases (docs/RELEASE.md).
    public static func newest(in releases: [UpdateRelease], current: ReleaseVersion) -> AvailableUpdate? {
        let candidates = releases.compactMap { release -> (ReleaseVersion, UpdateRelease)? in
            guard !release.draft, let version = ReleaseVersion(tag: release.tagName), version > current,
                  current.isPrerelease || !version.isPrerelease, trusted(release.htmlURL) else { return nil }
            return (version, release)
        }
        guard let (version, release) = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        let name = archiveName(version)
        let archive = release.assets.first { $0.name == name && trusted($0.browserDownloadURL) && $0.size > 0 && $0.size <= maximumArchiveSize }
        let signature = release.assets.first { $0.name == name + ".sig" && trusted($0.browserDownloadURL) && $0.size <= 1024 }
        let signed = archive == nil ? nil : signature
        return AvailableUpdate(version: version, page: release.htmlURL, archive: archive?.browserDownloadURL,
                               signature: signed?.browserDownloadURL, archiveSize: archive?.size ?? 0,
                               archiveAPI: archive?.apiURL.flatMap(trustedAPI), signatureAPI: signed?.apiURL.flatMap(trustedAPI))
    }
    /// Release pages and downloads stay on github.com (downloads then redirect to GitHub's storage).
    static func trusted(_ url: URL) -> Bool { url.scheme == "https" && url.host == "github.com" }
    /// Only this repository's asset endpoints: `https://api.github.com/repos/ChyiYaqing/nebula-gui/releases/assets/<id>`.
    static func trustedAPI(_ url: URL) -> URL? {
        let prefix = "https://api.github.com/repos/ChyiYaqing/nebula-gui/releases/assets/"
        let text = url.absoluteString
        let id = text.dropFirst(prefix.count)
        guard text.hasPrefix(prefix), !id.isEmpty, id.count <= 20, id.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return url
    }
}

public enum UpdateSignature {
    /// Ed25519 over the exact archive bytes. Both values are Base64; the key is the raw 32 bytes.
    public static func verify(_ archive: Data, signature: Data, publicKey: String) throws {
        let keyText = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyText.isEmpty else {
            throw BackendProblem(code: "update_key_missing", message: "此版本没有内置更新签名公钥，无法自动安装。请从发布页手动下载。")
        }
        guard let keyData = Data(base64Encoded: keyText), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw BackendProblem(code: "update_key_invalid", message: "内置更新签名公钥无效，无法自动安装。")
        }
        let signatureText = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: signatureText), raw.count == 64, key.isValidSignature(raw, for: archive) else {
            throw BackendProblem(code: "update_signature_invalid", message: "更新包签名校验失败，已放弃安装。")
        }
    }
}

/// Checks a downloaded, signature-verified archive and the App inside it. Nothing here
/// touches the installed App.
public enum UpdatePackage {
    /// Extracts with ditto into `directory` and returns the validated Nebula.app.
    public static func extract(_ archive: URL, into directory: URL, expected: ReleaseVersion, bundleIdentifier: String) throws -> URL {
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], failure: "更新包无法解压。")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "__MACOSX" }
        guard entries == ["Nebula.app"] else { throw invalid("更新包内容与预期不符。") }
        let app = directory.appendingPathComponent("Nebula.app", isDirectory: true)
        try validate(app, expected: expected, bundleIdentifier: bundleIdentifier)
        return app
    }
    public static func validate(_ app: URL, expected: ReleaseVersion, bundleIdentifier: String) throws {
        let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw invalid("更新包内缺少有效的 App。")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier, info["CFBundleExecutable"] as? String == "NebulaGUI" else {
            throw invalid("更新包不是 Nebula App。")
        }
        guard info["NebulaReleaseVersion"] as? String == expected.description else {
            throw invalid("更新包版本与发布版本不一致。")
        }
        // Ad-hoc signatures prove integrity only; the origin was proven by UpdateSignature.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], failure: "更新包代码签名不完整。")
    }
    private static func invalid(_ message: String) -> BackendProblem { BackendProblem(code: "update_package_invalid", message: message) }
    private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw invalid(failure) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw invalid(failure) }
    }
}

/// Replaces the installed App bundle by two renames in its own directory.
public enum UpdateInstaller {
    /// Why the App at `bundle` cannot replace itself, or nil when it can.
    public static func locationProblem(_ bundle: URL) -> BackendProblem? {
        let path = bundle.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return BackendProblem(code: "update_location", message: "Nebula 未从“应用程序”文件夹运行，无法自动更新。请先将 Nebula 拖到“应用程序”文件夹再打开。")
        }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent), FileManager.default.isWritableFile(atPath: bundle.path) else {
            return BackendProblem(code: "update_permission", message: "当前用户无权替换 Nebula 所在位置的 App，请从发布页手动下载安装。")
        }
        return nil
    }
    /// A directory on the same volume as `bundle`, so the final moves are renames.
    public static func stagingDirectory(for bundle: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
    }
    /// The original App stays in place until the new one is ready, and is restored if
    /// the second rename fails.
    public static func replace(_ bundle: URL, with staged: URL) throws {
        let manager = FileManager.default
        let backup = bundle.deletingLastPathComponent().appendingPathComponent(".Nebula-update-\(UUID().uuidString).app", isDirectory: true)
        do { try manager.moveItem(at: bundle, to: backup) }
        catch { throw BackendProblem(code: "update_replace_failed", message: "无法替换当前 App，原 App 保持不变。") }
        do { try manager.moveItem(at: staged, to: bundle) }
        catch {
            try? manager.moveItem(at: backup, to: bundle)
            throw BackendProblem(code: "update_replace_failed", message: "无法替换当前 App，原 App 保持不变。")
        }
        // The running process keeps its mapped code; the old bundle is no longer needed.
        try? manager.removeItem(at: backup)
    }
}
