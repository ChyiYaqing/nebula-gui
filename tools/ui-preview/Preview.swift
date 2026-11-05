import AppKit
import SwiftUI
import NebulaClient

/// Development-only executable: no production transport, store, observer or helper.
@MainActor final class PreviewBackend: AppBackend {
    var calls = 0
    func send<T: Decodable & Sendable>(_ request: BackendRequest, as type: T.Type) async throws -> T {
        calls += 1
        throw BackendProblem(code: "backend_unavailable", message: "合成预览不连接后台")
    }
    func recover() async throws -> ConnectionStatus { throw BackendProblem(code: "preview_only", message: "合成预览") }
    func completeAuthorizedRemoval() async throws {}
    func shutdown(permanently: Bool) async throws {}
}

@main struct UIPreview {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        func option(_ name: String, fallback: String = "") -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
            return args[i + 1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dark = option("--appearance") == "dark"
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backend = PreviewBackend()
        let model = AppModel(client: backend, wait: { _ in try await Task.sleep(nanoseconds: 600_000_000_000) })
        let first = try JSONDecoder().decode(NetworkProfile.self, from: Data(#"{"id":"preview-first","name":"研发网络 · 合成预览","device":"preview-mac","networks":["192.0.2.10/24"],"fingerprint":"a012b345c678d901e234f567a890b123c456d789e012f345a678b901c234d567e890","expiresAt":"2030-01-01T00:00:00Z","importedAt":"2026-01-01T00:00:00Z","version":"preview","digest":"preview"}"#.utf8))
        let second = try JSONDecoder().decode(NetworkProfile.self, from: Data(#"{"id":"preview-second","name":"家庭网络 · 合成预览","device":"preview-mac","networks":["198.51.100.10/24"],"fingerprint":"preview","expiresAt":"2030-01-01T00:00:00Z","importedAt":"2026-01-01T00:00:00Z","version":"preview","digest":"preview"}"#.utf8))
        model.profiles = [first, second]; model.selectedID = first.id
        model.authorization = try JSONDecoder().decode(AuthorizationState.self, from: Data(#"{"available":true}"#.utf8))
        let scenario = option("--scenario", fallback: "connected")
        let snapshot = option("--snapshot")
        let peers = try JSONDecoder().decode([KnownPeer].self, from: Data(#"[{"name":"开发主机","addresses":["192.0.2.12"],"pending":false},{"name":"文件服务器","addresses":["192.0.2.20"],"pending":false},{"name":"等待握手的测试节点","addresses":["192.0.2.30"],"pending":true}]"#.utf8))
        Task { @MainActor in
            if args.contains("--verify-isolation") {
                do {
                    try await AuthorizationRunner.execute(AuthorizationPlan.uninstall())
                    fatalError("Preview allowed a system operation")
                } catch let problem as BackendProblem {
                    precondition(problem.code == "preview_only")
                } catch { fatalError("Unexpected isolation error: \(error)") }
                await model.manageAuthorization(removing: true)
                precondition(model.problem?.code == "preview_only" && !model.busy && backend.calls == 0)
                model.problem = nil
                await model.setNotifications(true)
                precondition(model.problem == nil && model.notificationText == "合成预览不修改系统通知或偏好设置。" && !model.notificationsEnabled)
                await model.setNotifications(false)
                precondition(!model.notificationsEnabled && backend.calls == 0)
                await model.sendTestNotification()
                precondition(model.problem == nil && model.notificationText == "合成预览不发送系统通知。" && !model.notificationsBusy && backend.calls == 0)
                print("PASS preview isolation: authorization runner, uninstall flow, notifications and test notification rejected; no backend calls")
                app.stop(nil)
                app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
                return
            }
            if ["connected", "other", "busy", "unavailable"].contains(scenario) || scenario.hasPrefix("probe-") {
                model.status = ConnectionStatus(state: "started", profileID: first.id, error: nil, peers: peers, startedAt: "2026-11-05T02:00:00Z")
                if scenario == "other" { model.selectedID = second.id }
                if scenario == "busy" { model.busy = true; model.connectionBusy = true }
            }
            if scenario.hasPrefix("probe-") {
                // Many synthetic nodes: feedback must stay beside the tested row and above the list.
                let many = try! JSONDecoder().decode([KnownPeer].self, from: Data(("[" + (1...14).map {
                    #"{"name":"合成节点 \#($0)","addresses":["192.0.2.\#(40 + $0)"],"pending":\#($0 % 4 == 0)}"#
                }.joined(separator: ",") + "]").utf8))
                model.status = ConnectionStatus(state: "started", profileID: first.id, error: nil, peers: peers + many, startedAt: "2026-11-05T02:00:00Z")
                var probe = NodeProbe(address: "192.0.2.41", profileID: first.id, startedAt: "2026-11-05T02:00:00Z", generation: 0)
                let reply = #"{"address":"192.0.2.41","sent":3,"received":RECEIVED,"averageMS":AVERAGE,"observedAt":"2026-11-05T02:10:00Z"}"#
                if scenario == "probe-reply" {
                    probe.result = try! JSONDecoder().decode(NodeProbeResult.self, from: Data(reply.replacingOccurrences(of: "RECEIVED", with: "2").replacingOccurrences(of: "AVERAGE", with: "18.4").utf8))
                }
                if scenario == "probe-silent" {
                    probe.result = try! JSONDecoder().decode(NodeProbeResult.self, from: Data(reply.replacingOccurrences(of: "RECEIVED", with: "0").replacingOccurrences(of: "AVERAGE", with: "null").utf8))
                }
                if scenario == "probe-error" { probe.problem = BackendProblem(code: "probe_rate_limited", message: "合成错误：请稍候再测试节点。") }
                model.probe = probe; model.probeAddress = "192.0.2.99"
            }
            if scenario == "empty" { model.profiles = []; model.selectedID = nil }
            if scenario == "missing" || scenario == "unavailable" { model.authorization = .missing }
            if scenario == "failed" || scenario == "failed-other" {
                let error = BackendProblem(code: "cleanup_incomplete", message: "合成错误：连接清理尚未确认，请重试。")
                model.status = ConnectionStatus(state: "failed", profileID: first.id, error: error, peers: [])
                model.problem = error
            }
            if scenario == "recovering" || scenario == "recovering-other" { await model.connectSelected() }
            if scenario.hasSuffix("-other") { model.selectedID = second.id }
            let baselineCalls = backend.calls
            let page = WorkspacePage(rawValue: option("--page", fallback: "overview")) ?? .overview
            let root: AnyView
            if args.contains("--menu") { root = AnyView(MenuContent(model: model)) }
            else { root = AnyView(MainView(model: model, page: page)) }
            let view = NSHostingView(rootView: root
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { if args.contains("--disable-animations") { $0.disablesAnimations = true } })
            let width = args.contains("--menu") ? 356 : max(760, Double(option("--width", fallback: "900")) ?? 900)
            let height = args.contains("--menu") ? 680.0 : 720.0
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Nebula UI Preview · 合成数据 · 不连接"
            window.contentView = view
            window.setContentSize(NSSize(width: width, height: height)); window.center()
            window.isReleasedWhenClosed = false
            if snapshot.isEmpty && !args.contains("--background") { window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
            else { window.orderBack(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                view.layoutSubtreeIfNeeded()
                guard backend.calls == baselineCalls else { fatalError("Rendering sent a backend request") }
                if !snapshot.isEmpty {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No preview bitmap") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No preview PNG") }
                    do { try png.write(to: URL(fileURLWithPath: snapshot)) }
                    catch { fatalError("Cannot save preview: \(error)") }
                    print("PASS isolated preview: \(scenario) / \(page.rawValue) / \(dark ? "dark" : "light") / \(Int(width)) — no render requests")
                    window.orderOut(nil)
                    app.stop(nil)
                    app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
                }
                withExtendedLifetime(window) {}
            }
        }
        app.run()
    }
}
