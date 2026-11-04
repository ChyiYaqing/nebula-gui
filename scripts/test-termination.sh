#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nebula-termination.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Probe.swift" <<'SWIFT'
import AppKit

// Compile the production delegate against a controllable, asynchronous cleanup.
@MainActor final class AppModel {
    var calls = 0
    func shutdown() async -> Bool {
        calls += 1
        print("cleanup \(calls)")
        try? await Task.sleep(nanoseconds: 50_000_000)
        if CommandLine.arguments.contains("retry"), calls == 1 { return false }
        return true
    }
}
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let production = AppDelegate()
    override init() {
        super.init()
        if !CommandLine.arguments.contains("no-model") { production.model = AppModel() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if let model = self.production.model {
                await model.quit()
                if CommandLine.arguments.contains("duplicate") { await model.quit() }
            } else { NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("retry") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in await self.production.model?.quit() }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        production.applicationShouldTerminate(sender)
    }
}
@main struct Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
SWIFT
swiftc -parse-as-library "${NEBULA_GUI_TEST_DELEGATE:-$ROOT/apps/macos/Sources/NebulaGUI/AppDelegate.swift}" "$WORK/Probe.swift" -o "$WORK/probe"
python3 - "$WORK/probe" <<'PY'
import subprocess, sys
for mode, expected_calls in [('success', 1), ('retry', 2), ('duplicate', 1), ('no-model', 0)]:
    try:
        result = subprocess.run([sys.argv[1], mode], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired as error:
        raise SystemExit(f'FAIL {mode}: application termination deadlocked') from error
    assert result.returncode == 0, (mode, result.returncode, result.stderr)
    assert result.stdout.splitlines() == [f'cleanup {n}' for n in range(1, expected_calls + 1)], (mode, result.stdout)
    print(f'PASS termination: {mode}')
PY
