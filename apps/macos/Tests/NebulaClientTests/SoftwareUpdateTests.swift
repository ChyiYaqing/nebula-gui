import CryptoKit
import Foundation
import XCTest
@testable import NebulaClient

final class SoftwareUpdateTests: XCTestCase {
    private func version(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }

    func testVersionsFollowReleaseNumbering() {
        XCTAssertEqual(ReleaseVersion("0.1.0-rc1")?.description, "0.1.0-rc1")
        XCTAssertEqual(ReleaseVersion(tag: "v1.2.3")?.description, "1.2.3")
        for invalid in ["0.1", "00.1.0", "0.1.0-rc0", "0.1.0-rc01", "0.1.0-beta1", "v0.1.0", "0.1.0\n", " 0.1.0", "0.1.0-rc1-rc2"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
        XCTAssertNil(ReleaseVersion(tag: "0.1.0"))
        let ordered = ["0.1.0-rc1", "0.1.0-rc2", "0.1.0-rc10", "0.1.0", "0.1.1-rc1", "0.1.1", "0.2.0", "1.0.0"].map(version)
        XCTAssertEqual(ordered, ordered.shuffled().sorted())
        XCTAssertFalse(version("0.1.0") < version("0.1.0"))
    }

    private func release(_ tag: String, draft: Bool = false, assets: [String]? = nil, host: String = "github.com", size: Int = 1000) -> [String: Any] {
        let names = assets ?? ["Nebula-\(tag)-macos-universal.zip", "Nebula-\(tag)-macos-universal.zip.sig", "Nebula-\(tag)-macos-universal.dmg"]
        return ["tag_name": tag, "draft": draft, "prerelease": true, "html_url": "https://github.com/ChyiYaqing/nebula-gui/releases/tag/\(tag)",
                "assets": names.map { ["name": $0, "size": $0.hasSuffix(".sig") ? 88 : size,
                                       "browser_download_url": "https://\(host)/ChyiYaqing/nebula-gui/releases/download/\(tag)/\($0)"] }]
    }
    private func decode(_ releases: [[String: Any]]) throws -> [UpdateRelease] {
        try JSONDecoder().decode([UpdateRelease].self, from: JSONSerialization.data(withJSONObject: releases))
    }

    func testCatalogChoosesTheNewestEligibleRelease() throws {
        let releases = try decode([release("v0.1.0-rc1"), release("v0.1.0-rc2"), release("v0.2.0", draft: true), release("v0.1.1-rc1"), release("v0.1.0"), release("not-a-version")])
        // A candidate build follows newer candidates; drafts are never offered.
        let fromCandidate = UpdateCatalog.newest(in: releases, current: version("0.1.0-rc1"))
        XCTAssertEqual(fromCandidate?.version, version("0.1.1-rc1"))
        XCTAssertEqual(fromCandidate?.installable, true)
        XCTAssertEqual(fromCandidate?.archive?.lastPathComponent, "Nebula-v0.1.1-rc1-macos-universal.zip")
        // A final build is offered final releases only.
        XCTAssertNil(UpdateCatalog.newest(in: releases, current: version("0.1.0")))
        XCTAssertEqual(UpdateCatalog.newest(in: try decode([release("v0.1.0"), release("v0.2.0-rc1")]), current: version("0.0.9"))?.version, version("0.1.0"))
        XCTAssertNil(UpdateCatalog.newest(in: releases, current: version("9.0.0")))
    }

    func testCatalogReportsReleasesThatCannotBeInstalledAutomatically() throws {
        let unsigned = UpdateCatalog.newest(in: try decode([release("v0.2.0", assets: ["Nebula-v0.2.0-macos-universal.zip"])]), current: version("0.1.0"))
        XCTAssertEqual(unsigned?.version, version("0.2.0"))
        XCTAssertEqual(unsigned?.installable, false)
        let signatureOnly = UpdateCatalog.newest(in: try decode([release("v0.2.0", assets: ["Nebula-v0.2.0-macos-universal.zip.sig"])]), current: version("0.1.0"))
        XCTAssertEqual(signatureOnly?.installable, false)
        let foreign = UpdateCatalog.newest(in: try decode([release("v0.2.0", host: "example.com")]), current: version("0.1.0"))
        XCTAssertEqual(foreign?.installable, false, "downloads stay on github.com")
        let oversized = UpdateCatalog.newest(in: try decode([release("v0.2.0", size: UpdateCatalog.maximumArchiveSize + 1)]), current: version("0.1.0"))
        XCTAssertEqual(oversized?.installable, false)
    }

    func testCatalogKeepsOnlyThisRepositorysAPIAssetAddresses() throws {
        func offer(_ api: (String) -> String) throws -> AvailableUpdate? {
            var entry = release("v0.2.0")
            entry["assets"] = (entry["assets"] as! [[String: Any]]).map { var asset = $0; asset["url"] = api($0["name"] as! String); return asset }
            return UpdateCatalog.newest(in: try decode([entry]), current: version("0.1.0"))
        }
        let base = "https://api.github.com/repos/ChyiYaqing/nebula-gui/releases/assets/"
        let trusted = try offer { $0.hasSuffix(".sig") ? base + "2" : base + "1" }
        XCTAssertEqual(trusted?.archiveAPI?.absoluteString, base + "1")
        XCTAssertEqual(trusted?.signatureAPI?.absoluteString, base + "2")
        XCTAssertNil(try offer { _ in base }.flatMap(\.archiveAPI))
        for untrusted in ["http://api.github.com/repos/ChyiYaqing/nebula-gui/releases/assets/1",
                          "https://api.github.com/repos/someone/nebula-gui/releases/assets/1",
                          "https://example.com/repos/ChyiYaqing/nebula-gui/releases/assets/1",
                          base + "1/../../../../other", base + "1?redirect=x"] {
            let update = try offer { _ in untrusted }
            XCTAssertEqual(update?.installable, true, "the github.com download is unaffected")
            XCTAssertNil(update?.archiveAPI, untrusted)
            XCTAssertNil(update?.signatureAPI, untrusted)
        }
        let withoutAPI = UpdateCatalog.newest(in: try decode([release("v0.2.0")]), current: version("0.1.0"))
        XCTAssertEqual(withoutAPI?.installable, true, "assets without an API address still decode")
        XCTAssertNil(withoutAPI?.archiveAPI)
    }

    func testSignatureMustMatchTheEmbeddedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("archive".utf8)
        let signature = Data((try key.signature(for: archive).base64EncodedString() + "\n").utf8)
        XCTAssertNoThrow(try UpdateSignature.verify(archive, signature: signature, publicKey: publicKey))
        func code(_ body: () throws -> Void) -> String? {
            do { try body(); return nil } catch { return (error as? BackendProblem)?.code }
        }
        XCTAssertEqual(code { try UpdateSignature.verify(Data("changed".utf8), signature: signature, publicKey: publicKey) }, "update_signature_invalid")
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(code { try UpdateSignature.verify(archive, signature: signature, publicKey: other) }, "update_signature_invalid")
        XCTAssertEqual(code { try UpdateSignature.verify(archive, signature: Data("garbage".utf8), publicKey: publicKey) }, "update_signature_invalid")
        XCTAssertEqual(code { try UpdateSignature.verify(archive, signature: signature, publicKey: "") }, "update_key_missing")
        XCTAssertEqual(code { try UpdateSignature.verify(archive, signature: signature, publicKey: "AAAA") }, "update_key_invalid")
    }

    // MARK: - Packages and replacement on temporary directories only

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nebula-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// A minimal ad-hoc signed bundle; its executable is a copy of /usr/bin/true.
    @discardableResult private func makeApp(at app: URL, identifier: String = "net.nebula.gui.development", release: String = "0.2.0", sign: Bool = true) throws -> URL {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("NebulaGUI").path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "NebulaGUI", "CFBundlePackageType": "APPL", "NebulaReleaseVersion": release]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign { try run("/usr/bin/codesign", "--force", "--sign", "-", app.path) }
        return app
    }
    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
    private func problem(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? BackendProblem)?.code ?? "\(error)" }
    }

    func testPackageExtractsAndValidatesTheApp() throws {
        let root = try temporaryDirectory()
        let source = try makeApp(at: root.appendingPathComponent("source/Nebula.app"))
        let archive = root.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path)
        let out = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let app = try UpdatePackage.extract(archive, into: out, expected: version("0.2.0"), bundleIdentifier: "net.nebula.gui.development")
        XCTAssertEqual(app.lastPathComponent, "Nebula.app")
        let wrongVersion = root.appendingPathComponent("wrong"); try FileManager.default.createDirectory(at: wrongVersion, withIntermediateDirectories: false)
        XCTAssertEqual(problem { _ = try UpdatePackage.extract(archive, into: wrongVersion, expected: self.version("0.3.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
        let corrupt = root.appendingPathComponent("corrupt.zip"); try Data("not a zip".utf8).write(to: corrupt)
        let corruptOut = root.appendingPathComponent("corrupt"); try FileManager.default.createDirectory(at: corruptOut, withIntermediateDirectories: false)
        XCTAssertEqual(problem { _ = try UpdatePackage.extract(corrupt, into: corruptOut, expected: self.version("0.2.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
    }

    func testPackageRejectsAnotherAppOrBrokenSignature() throws {
        let root = try temporaryDirectory()
        let other = try makeApp(at: root.appendingPathComponent("a/Nebula.app"), identifier: "com.example.other")
        XCTAssertEqual(problem { try UpdatePackage.validate(other, expected: self.version("0.2.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
        let unsigned = try makeApp(at: root.appendingPathComponent("b/Nebula.app"), sign: false)
        // The copied /usr/bin/true keeps Apple's signature, which does not seal this bundle.
        XCTAssertEqual(problem { try UpdatePackage.validate(unsigned, expected: self.version("0.2.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
        let tampered = try makeApp(at: root.appendingPathComponent("c/Nebula.app"))
        try Data("extra".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/NebulaGUI"), options: .atomic)
        XCTAssertEqual(problem { try UpdatePackage.validate(tampered, expected: self.version("0.2.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
        let link = root.appendingPathComponent("d/Nebula.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("c/Nebula.app"))
        XCTAssertEqual(problem { try UpdatePackage.validate(link, expected: self.version("0.2.0"), bundleIdentifier: "net.nebula.gui.development") }, "update_package_invalid")
    }

    func testReplacementSwapsBundlesAndKeepsTheOriginalOnFailure() throws {
        let root = try temporaryDirectory()
        let installed = try makeApp(at: root.appendingPathComponent("Applications/Nebula.app"), release: "0.1.0", sign: false)
        let staged = try makeApp(at: root.appendingPathComponent("staging/Nebula.app"), release: "0.2.0", sign: false)
        XCTAssertNil(UpdateInstaller.locationProblem(installed))
        try UpdateInstaller.replace(installed, with: staged)
        func release() throws -> String? {
            let data = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
            return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["NebulaReleaseVersion"] as? String
        }
        XCTAssertEqual(try release(), "0.2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["Nebula.app"], "no backup is left behind")
        XCTAssertEqual(problem { try UpdateInstaller.replace(installed, with: root.appendingPathComponent("missing/Nebula.app")) }, "update_replace_failed")
        XCTAssertEqual(try release(), "0.2.0", "a failed replacement restores the installed App")
    }

    func testReplacementRefusesLocationsItCannotWrite() throws {
        XCTAssertEqual(UpdateInstaller.locationProblem(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Nebula.app"))?.code, "update_location")
        XCTAssertEqual(UpdateInstaller.locationProblem(URL(fileURLWithPath: "/Volumes/Nebula v0.2.0/Nebula.app"))?.code, "update_location")
        let root = try temporaryDirectory()
        let installed = try makeApp(at: root.appendingPathComponent("locked/Nebula.app"), sign: false)
        let parent = installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertEqual(UpdateInstaller.locationProblem(installed)?.code, "update_permission")
    }
}
