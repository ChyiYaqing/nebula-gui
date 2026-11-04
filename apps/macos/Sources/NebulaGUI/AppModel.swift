import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NebulaClient

@MainActor final class AppModel: ObservableObject {
    @Published var authorization = AuthorizationState.missing
    @Published var showAuthorizationReview = false
    @Published var removingAuthorization = false
    @Published var events: [ConnectionEvent] = []
    private var refreshingStatus = false
    @Published var profiles: [NetworkProfile] = []
    @Published var selectedID: String?
    @Published var status = ConnectionStatus.disconnected
    @Published var problem: BackendProblem?
    @Published var busy = false
    @Published var importing = false
    @Published var candidate: NetworkProfile?
    @Published var importName = ""
    @Published var importPath: String?
    @Published var replacementID: String?
    @Published var showDetails = false
    private var authorizationInProgress = false
    private var files: [String: String] = [:]
    private var timer: Timer?
    private let client: BackendClient
    var selected: NetworkProfile? { profiles.first { $0.id == selectedID } }
    var active: NetworkProfile? { profiles.first { $0.id == status.profileID } }
    var isCurrentStarted: Bool { status.isStarted && status.profileID == selectedID }
    var statusText: String {
        if busy { return "正在处理" }
        if status.isStarted { return "隧道已启动" }
        if status.state == "failed" { return "连接未完成" }
        return profiles.isEmpty ? "等待导入" : "未连接"
    }
    init() {
        let arguments = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = argument("--data-dir").map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("NebulaGUI", isDirectory: true)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nebula-gui-backend")
        client = BackendClient(executable: executable, store: store)
        Task {
            await refresh()
            if let path = argument("--import") { await preview(path: path) }
        }
        startPolling()
    }
    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, !self.busy else { return }; await self.refreshStatus() }
        }
    }
    func refresh() async {
        do {
            profiles = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
            if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id }
            await refreshStatus()
        } catch { setProblem(error) }
    }
    func refreshStatus() async {
        guard !refreshingStatus else { return }
        refreshingStatus = true
        defer { refreshingStatus = false }
        do {
            status = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
            authorization = try await client.send(BackendRequest(method: "authorization"), as: AuthorizationState.self)
            if showDetails { events = try await client.send(BackendRequest(method: "events"), as: [ConnectionEvent].self) }
        }
        catch { setProblem(error) }
    }
    func chooseImport(replacing: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择 config.yaml，或包含配置、CA、主机证书和密钥的文件夹。"
        panel.prompt = "检查配置"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.files = [:]; self.replacementID = replacing
                await self.preview(path: url.path)
            }
        }
    }
    func preview(path: String, preservingOverrides: Bool = false) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        if !preservingOverrides { files = [:] }
        importing = true; candidate = nil; problem = nil; importPath = path
        do {
            let profile = try await client.send(BackendRequest(method: "preview", path: path, files: files), as: NetworkProfile.self)
            candidate = profile; importName = profile.name
        } catch { setProblem(error) }
    }
    func supplementFile() {
        guard let role = problem?.field?.split(separator: ".").last.map(String.init), ["ca", "cert", "key"].contains(role) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "补选 \(role) 文件，原始 config.yaml 不会被修改。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.files[role] = url.path; if let path = self.importPath { await self.preview(path: path, preservingOverrides: true) } }
        }
    }
    func confirmImport() async {
        guard let candidate, let path = importPath, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let saved = try await client.send(BackendRequest(method: "import", path: path, profileID: replacementID,
                name: importName, digest: candidate.digest, files: files), as: NetworkProfile.self)
            importing = false; self.candidate = nil; problem = nil
            await refresh(); selectedID = saved.id
        } catch { setProblem(error) }
    }
    func connectSelected() async {
        if !authorization.available { showAuthorizationReview = true; return }
        if isCurrentStarted { await disconnect(); return }
        guard !busy, let selected else { return }
        busy = true; problem = nil; defer { busy = false }
        do {
            if status.isStarted { status = try await client.send(BackendRequest(method: "disconnect"), as: ConnectionStatus.self) }
            status = try await client.send(BackendRequest(method: "connect", profileID: selected.id), as: ConnectionStatus.self)
        } catch { setProblem(error); await refreshStatus() }
    }
    func disconnect() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { status = try await client.send(BackendRequest(method: "disconnect"), as: ConnectionStatus.self); problem = nil }
        catch { setProblem(error) }
    }
    func removeSelected() async {
        guard let selected, !busy else { return }
        let alert = NSAlert(); alert.messageText = "移除 \(selected.name)？"
        alert.informativeText = "将删除应用保存的配置与凭据副本，原始文件保持不变。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; defer { busy = false }
        do { _ = try await client.send(BackendRequest(method: "remove", profileID: selected.id), as: Acknowledgement.self); await refresh() }
        catch { setProblem(error) }
    }
    func rollbackSelected() async {
        guard let selected, !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await client.send(BackendRequest(method: "rollback", profileID: selected.id), as: NetworkProfile.self); await refresh() }
        catch { setProblem(error) }
    }
    func exportDiagnostics() async {
        // Only the backend's fixed diagnostic schema is exported, never the original YAML.
        struct Event: Codable, Sendable { let time: String; let code: String }
        struct Diagnostic: Codable, Sendable {
            let schema: Int; let kernelRevision: String; let state: String
            let profileCount: Int; let knownPeerCount: Int; let events: [Event]; let generatedAt: String
        }
        do {
            let data = try await client.send(BackendRequest(method: "diagnostics"), as: Diagnostic.self)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "nebula-diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.message = "仅包含版本、状态、数量和事件代码；不包含地址、设备名、配置或密钥。"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch { setProblem(error) }
    }
    func manageAuthorization(removing: Bool) async {
        guard !busy, !status.isStarted else { return }
        busy = true; authorizationInProgress = true; problem = nil; showAuthorizationReview = false
        defer { busy = false; authorizationInProgress = false }
        do {
            let plan = removing ? AuthorizationPlan.uninstall() : try AuthorizationPlan.install(bundle: Bundle.main.bundleURL, uid: getuid())
            try await AuthorizationRunner.execute(plan)
            for _ in 0..<20 {
                authorization = try await client.send(BackendRequest(method: "authorization"), as: AuthorizationState.self)
                if authorization.available != removing { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if authorization.available == removing {
                throw BackendProblem(code: "authorization_unavailable", message: "系统操作已完成，但后台状态尚未达到预期。请刷新检查。")
            }
            problem = nil
            await refreshStatus()
        } catch { setProblem(error) }
    }
    func copyAddress() {
        guard let address = selected?.networks.first?.split(separator: "/").first else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(address), forType: .string)
    }
    func shutdown() async -> Bool {
        if authorizationInProgress {
            problem = BackendProblem(code: "authorization_in_progress", message: "管理员授权仍在进行，请先完成或在系统窗口取消，再退出应用。")
            return false
        }
        timer?.invalidate()
        do { try await client.shutdown(); return true }
        catch { setProblem(error); startPolling(); return false }
    }
    func setProblem(_ error: Error) {
        problem = error as? BackendProblem ?? BackendProblem(code: "operation_failed", message: "操作未完成，请重试。")
    }
}
