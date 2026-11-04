import Foundation
import XCTest
@testable import NebulaClient

final class UpgradeTests: XCTestCase {
    func testUpgradeAndFailureRollbackInIsolatedFilesystem() throws {
        for scenario in ["success", "bootstrap-failure", "health-failure", "checksum-failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ng-upgrade-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appendingPathComponent("New ' App.app")
            let source = bundle.appendingPathComponent("Contents/Helpers/nebula-gui-helper")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("new helper".utf8).write(to: source)
            let library = root.appendingPathComponent("Library")
            let installed = root.appendingPathComponent(String(AuthorizationPlan.helperPath.dropFirst()))
            let plist = root.appendingPathComponent(String(AuthorizationPlan.plistPath.dropFirst()))
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old helper".utf8).write(to: installed)
            try Data("old plist".utf8).write(to: plist)
            try Data().write(to: root.appendingPathComponent("loaded"))
            for file in [installed, plist] { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            if scenario != "success" { try Data().write(to: root.appendingPathComponent(scenario)) }
            let launchctl = root.appendingPathComponent("launchctl")
            let sudo = root.appendingPathComponent("sudo")
            try writeExecutable(#"""
            #!/usr/bin/python3
            import pathlib, sys
            root = pathlib.Path(__file__).parent
            args = sys.argv[1:]
            loaded = root / 'loaded'
            with (root / 'commands').open('a') as f: f.write(' '.join(args) + '\n')
            if args[:2] == ['print', 'system/com.slack.nebula']: sys.exit(1)
            if args[0] == 'print': sys.exit(0 if loaded.exists() else 1)
            if args[0] == 'bootout':
                if args[1] != '--wait': sys.exit(55)
                loaded.unlink(missing_ok=True)
            if args[0] == 'bootstrap':
                if (root / 'bootstrap-failure').exists() and '<plist' in pathlib.Path(args[2]).read_text(): sys.exit(1)
                loaded.touch()
            """#, to: launchctl)
            try writeExecutable(#"""
            #!/usr/bin/python3
            import pathlib, sys
            root = pathlib.Path(__file__).parent
            payload = pathlib.Path(sys.argv[3]).read_text()
            sys.exit(1 if payload.startswith('new') and (root / 'health-failure').exists() else 0)
            """#, to: sudo)
            let plan = try AuthorizationPlan.install(bundle: bundle, uid: getuid(), upgrading: true)
            // Only this test's generated script is rewritten; every privileged
            // command is replaced before any execution. No system job is called.
            var script = plan.script.replacingOccurrences(of: "/Library", with: library.path)
            script = script.replacingOccurrences(of: "/bin/launchctl", with: AuthorizationPlan.shellQuote(launchctl.path))
                .replacingOccurrences(of: "/usr/bin/sudo", with: AuthorizationPlan.shellQuote(sudo.path))
                .replacingOccurrences(of: "/usr/sbin/chown", with: "/usr/bin/true")
                .replacingOccurrences(of: "/usr/bin/codesign", with: "/usr/bin/true")
                .replacingOccurrences(of: " = 0 ]", with: " = \(getuid()) ]")
            XCTAssertFalse(script.contains("/bin/launchctl"))
            XCTAssertFalse(script.contains("/usr/bin/sudo"))
            let file = root.appendingPathComponent("transaction.sh")
            try Data(script.utf8).write(to: file)
            if scenario == "checksum-failure" { try Data("changed after review".utf8).write(to: source) }
            let process = Process(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if scenario == "success" {
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
                XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "new helper")
            } else {
                XCTAssertNotEqual(process.terminationStatus, 0, scenario)
                XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "old helper", scenario)
                XCTAssertEqual(try String(contentsOf: plist, encoding: .utf8), "old plist", scenario)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("loaded").path), scenario)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.deletingLastPathComponent().appendingPathComponent(".install-lock").path))
        }
    }
    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
