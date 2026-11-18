import Foundation
import XCTest
@testable import NebulaClient

final class UpgradeTests: XCTestCase {
    func testUpgradeAndFailureRollbackInIsolatedFilesystem() throws {
        // slow-bootout: launchd keeps listing the job briefly after bootout returns.
        for scenario in ["success", "slow-bootout", "bootstrap-failure", "health-failure", "checksum-failure"] {
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
            try writeLaunchctl(to: launchctl)
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
            XCTAssertFalse(plan.script.contains("--wait"), "macOS 13 launchctl rejects bootout --wait")
            let file = root.appendingPathComponent("transaction.sh")
            try Data(script.utf8).write(to: file)
            if scenario == "checksum-failure" { try Data("changed after review".utf8).write(to: source) }
            let process = Process(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if scenario == "success" || scenario == "slow-bootout" {
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
                XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "new helper")
            } else {
                XCTAssertNotEqual(process.terminationStatus, 0, scenario)
                XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "old helper", scenario)
                XCTAssertEqual(try String(contentsOf: plist, encoding: .utf8), "old plist", scenario)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("loaded").path), scenario)
            let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
            if scenario != "checksum-failure" { XCTAssertTrue(commands.contains("bootout system/net.nebula.gui.helper"), scenario) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["nebula-gui-helper"], scenario)
        }
    }
    func testUninstallStopsHelperWithoutWaitFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ng-uninstall-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        let installed = root.appendingPathComponent(String(AuthorizationPlan.helperPath.dropFirst()))
        let plist = root.appendingPathComponent(String(AuthorizationPlan.plistPath.dropFirst()))
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old helper".utf8).write(to: installed); try Data("old plist".utf8).write(to: plist)
        try Data().write(to: root.appendingPathComponent("loaded"))
        try Data().write(to: root.appendingPathComponent("slow-bootout"))
        let launchctl = root.appendingPathComponent("launchctl")
        try writeLaunchctl(to: launchctl)
        let plan = AuthorizationPlan.uninstall()
        XCTAssertFalse(plan.script.contains("--wait"))
        let script = plan.script.replacingOccurrences(of: "/Library", with: library.path)
            .replacingOccurrences(of: "/bin/launchctl", with: AuthorizationPlan.shellQuote(launchctl.path))
            .replacingOccurrences(of: " = 0 ]", with: " = \(getuid()) ]")
        XCTAssertFalse(script.contains("/bin/launchctl"))
        let file = root.appendingPathComponent("uninstall.sh")
        try Data(script.utf8).write(to: file)
        let process = Process(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("loaded").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
    /// Mirrors macOS 13 launchctl: `bootout --wait` is a usage error (64), the
    /// failure seen on a real 13.7.8 upgrade. No system job is ever called.
    /// #118: a lock left by a killed transaction or a power loss must not block the GUI forever,
    /// while a transaction that is still running keeps its lock.
    func testLeftoverLockIsReclaimedButLiveHolderIsRespected() throws {
        let sysctl = Process(); let output = Pipe()
        sysctl.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); sysctl.arguments = ["-n", "kern.boottime"]
        sysctl.standardOutput = output; try sysctl.run(); sysctl.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let boot = try XCTUnwrap(text.split(separator: " ").dropFirst(3).first?.dropLast())
        // A process that has exited: its pid is not running (reuse within this test is not expected).
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
        let old = Date(timeIntervalSinceNow: -3600)
        let scenarios: [(name: String, lock: String?, legacy: Date?, reclaimed: Bool)] = [
            ("holder exited", "\(gone.processIdentifier) \(boot)\n", nil, true),
            ("restarted since", "\(getpid()) 1\n", nil, true),
            ("holder running", "\(getpid()) \(boot)\n", nil, false),
            ("unreadable holder", "not-a-pid \(boot)\n", nil, false),
            ("old directory lock", nil, old, true),
            ("recent directory lock", nil, Date(), false),
        ]
        for scenario in scenarios {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ng-lock-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appendingPathComponent("Library")
            let installed = root.appendingPathComponent(String(AuthorizationPlan.helperPath.dropFirst()))
            let plist = root.appendingPathComponent(String(AuthorizationPlan.plistPath.dropFirst()))
            let directory = installed.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old helper".utf8).write(to: installed); try Data("old plist".utf8).write(to: plist)
            try Data().write(to: root.appendingPathComponent("loaded"))
            if let lock = scenario.lock { try Data(lock.utf8).write(to: directory.appendingPathComponent(".install.lock")) }
            if let legacy = scenario.legacy {
                let lock = directory.appendingPathComponent(".install-lock")
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.modificationDate: legacy], ofItemAtPath: lock.path)
            }
            let launchctl = root.appendingPathComponent("launchctl")
            try writeLaunchctl(to: launchctl)
            let script = AuthorizationPlan.uninstall().script.replacingOccurrences(of: "/Library", with: library.path)
                .replacingOccurrences(of: "/bin/launchctl", with: AuthorizationPlan.shellQuote(launchctl.path))
                .replacingOccurrences(of: " = 0 ]", with: " = \(getuid()) ]")
            let file = root.appendingPathComponent("uninstall.sh")
            try Data(script.utf8).write(to: file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            if scenario.reclaimed {
                XCTAssertEqual(process.terminationStatus, 0, scenario.name)
                XCTAssertEqual(left, [], scenario.name)
            } else {
                XCTAssertEqual(process.terminationStatus, 79, scenario.name)
                XCTAssertEqual(left, [scenario.lock == nil ? ".install-lock" : ".install.lock", "nebula-gui-helper"], scenario.name)
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("loaded").path), scenario.name)
            }
        }
    }
    private func writeLaunchctl(to url: URL) throws {
        try writeExecutable(#"""
        #!/usr/bin/python3
        import pathlib, sys
        root = pathlib.Path(__file__).parent
        args = sys.argv[1:]
        loaded = root / 'loaded'
        linger = root / 'linger'
        with (root / 'commands').open('a') as f: f.write(' '.join(args) + '\n')
        if '--wait' in args: sys.exit(64)
        if args[:2] == ['print', 'system/com.slack.nebula']: sys.exit(1)
        if args[0] == 'print':
            if linger.exists():
                left = int(linger.read_text()) - 1
                if left > 0: linger.write_text(str(left))
                else: linger.unlink(); loaded.unlink(missing_ok=True)
                sys.exit(0)
            sys.exit(0 if loaded.exists() else 1)
        if args[0] == 'bootout':
            if not loaded.exists(): sys.exit(3)
            if (root / 'slow-bootout').exists(): linger.write_text('3')
            else: loaded.unlink()
        if args[0] == 'bootstrap':
            if (root / 'bootstrap-failure').exists() and '<plist' in pathlib.Path(args[2]).read_text(): sys.exit(1)
            loaded.touch()
        """#, to: url)
    }
    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
