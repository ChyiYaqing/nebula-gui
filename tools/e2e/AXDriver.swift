import AppKit
import ApplicationServices

// Drives one Nebula App instance, chosen by pid, through the accessibility API.
// usage: nebula-e2e-ax <pid> dump | click <label> | wait <text> <seconds> | absent <text> | quit <seconds>
// Exit codes: 0 ok, 1 expectation failed, 2 usage, 3 accessibility permission missing.
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage: nebula-e2e-ax <pid> dump|click|wait|absent|quit …"); exit(2) }
guard AXIsProcessTrusted() else { print("NOT_TRUSTED"); exit(3) }
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
/// SwiftUI publishes accessibility labels as an attributed description.
func label(_ element: AXUIElement) -> String {
    if let text = attribute(element, "AXAttributedDescription") as? NSAttributedString, !text.string.isEmpty { return text.string }
    for name in ["AXDescription", "AXTitle", "AXValue"] {
        if let text = attribute(element, name) as? String, !text.isEmpty { return text }
    }
    return ""
}
/// Visits every element of the main window; the visitor returns false to stop.
@discardableResult func walk(_ element: AXUIElement, _ visit: (AXUIElement, String) -> Bool) -> Bool {
    if !visit(element, attribute(element, "AXRole") as? String ?? "") { return false }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] where !walk(child, visit) { return false }
    return true
}
func mainWindows() -> [AXUIElement] {
    (attribute(app, "AXWindows") as? [AXUIElement] ?? []).filter { attribute($0, "AXTitle") as? String == "Nebula" }
}
func contents() -> [String] {
    var lines: [String] = []
    for window in mainWindows() {
        walk(window) { element, role in
            if role == "AXButton" { lines.append("B: \(label(element))") }
            else if role == "AXStaticText" { lines.append("T: \(label(element))") }
            return true
        }
    }
    return lines
}

switch args[2] {
case "dump":
    contents().forEach { print($0) }
case "click" where args.count == 4:
    var pressed = false
    for window in mainWindows() {
        walk(window) { element, role in
            guard role == "AXButton", label(element) == args[3] else { return true }
            pressed = AXUIElementPerformAction(element, "AXPress" as CFString) == .success
            return false
        }
    }
    if !pressed { print("no button: \(args[3])"); exit(1) }
case "wait" where args.count == 5:
    let deadline = Date().addingTimeInterval(Double(args[4]) ?? 5)
    while !contents().contains(where: { $0.contains(args[3]) }) {
        if Date() > deadline { print("timed out waiting for: \(args[3])"); exit(1) }
        usleep(200_000)
    }
case "absent" where args.count == 4:
    if contents().contains(where: { $0.contains(args[3]) }) { print("unexpected: \(args[3])"); exit(1) }
case "quit" where args.count == 4:
    // The same request as ⌘Q, so the App disconnects and cleans up before exiting.
    guard let running = NSRunningApplication(processIdentifier: pid) else { exit(0) }
    running.terminate()
    let deadline = Date().addingTimeInterval(Double(args[3]) ?? 20)
    // Without a run loop `isTerminated` never updates here; ask the kernel instead.
    while kill(pid, 0) == 0 {
        if Date() > deadline { print("still running after quit"); exit(1) }
        usleep(200_000)
    }
default:
    print("usage: nebula-e2e-ax <pid> dump|click <label>|wait <text> <seconds>|absent <text>|quit <seconds>"); exit(2)
}
