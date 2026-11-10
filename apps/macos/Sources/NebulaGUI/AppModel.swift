import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NebulaClient

/// Only the operations used by the model; production transport retains its own serial queue.
@MainActor protocol AppBackend {
    func send<T: Decodable & Sendable>(_ request: BackendRequest, as type: T.Type) async throws -> T
    func recover() async throws -> ConnectionStatus
    func shutdown(permanently: Bool) async throws
    func completeAuthorizedRemoval() async throws
}
extension BackendClient: AppBackend {}

@MainActor final class AppModel: ObservableObject {
    @Published var authorization = AuthorizationState.missing
    @Published var showAuthorizationReview = false
    @Published var removingAuthorization = false
    @Published var events: [ConnectionEvent] = []
    /// Kernel logs are fetched only while the logs page is open.
    @Published var kernelLogs: KernelLogPage?
    var logsVisible = false
    /// Latency history of the current connection, sampled only while the nodes page is open (#44).
    @Published var latency = LatencyHistory()
    /// Addresses whose detailed latency chart is open on the nodes page.
    @Published var latencyExpanded: Set<String> = []
    var nodesVisible = false
    /// The menu bar panel shows the same latency history (#65).
    var menuVisible = false
    /// Asks the main window to switch page, e.g. "view all nodes" from the menu.
    @Published var requestedPage: WorkspacePage?
    @Published var recoveryText = ""
    @Published var connectionBusy = false
    /// Launch at login (#63): mirrors the system login item; only `setLaunchAtLogin` changes it.
    @Published private(set) var loginItemState = LoginItemState.unavailable
    @Published var loginItemNotice: String?
    @Published var autoConnect = false { didSet { defaults.set(autoConnect, forKey: Self.autoConnectKey) } }
    private(set) var lastConnectedID: String? {
        get { defaults.string(forKey: Self.lastConnectedKey) }
        set { defaults.set(newValue, forKey: Self.lastConnectedKey) }
    }
    private static let autoConnectKey = "autoConnectAtLaunch", lastConnectedKey = "lastConnectedProfileID"
    /// The user's "open at login" choice, kept because the system's record is per build identity (#67).
    private static let launchAtLoginKey = "launchAtLogin"
    private let defaults: UserDefaults
    private let loginItem: any LoginItemControl
    private var autoConnectAttempted = false
    @Published var automaticRecovery = true { didSet { recovery.setEnabled(automaticRecovery); recoveryTask?.cancel(); recoveryTask = nil; evaluateRecovery() } }
    @Published var notificationsBusy = false
    @Published var notificationsEnabled = false
    @Published var notificationText = "到期提醒未开启"
    @Published var upgradingAuthorization = false
    /// Software update (#69): nil in tests, previews and isolated --data-dir runs.
    private let updater: (any SoftwareUpdating)?
    @Published private(set) var updateState = UpdateState.idle
    @Published var automaticUpdateChecks = true { didSet { defaults.set(automaticUpdateChecks, forKey: Self.automaticUpdatesKey) } }
    private static let automaticUpdatesKey = "automaticUpdateChecks", lastUpdateCheckKey = "lastUpdateCheck"
    private var updateTimer: Timer?
    private var recovery = SessionRecovery()
    private var recoveryTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var environmentMonitor: ConnectionEnvironment?
    private var sleeping = false
    private var networkAvailable = true
    private var shuttingDown = false
    private var notificationsAllowed = true
    private var injectedNotifications: CertificateNotifications?
    private lazy var certificateNotifications = injectedNotifications ?? CertificateNotifications(allowDelivery: notificationsAllowed)
    /// Reminder plans derive from the network list; an empty list before the first load is unknown, not empty.
    private var profilesLoaded = false
    var canCancelConnection: Bool { connectionBusy || (recovery.desiredProfileID != nil && !recoveryText.isEmpty) }
    /// The network that automatic recovery targets; status.profileID may already be cleared.
    var recoveryProfileID: String? { recovery.desiredProfileID }
    private var refreshingStatus = false
    @Published var profiles: [NetworkProfile] = []
    @Published var selectedID: String?
    @Published var status = ConnectionStatus.disconnected {
        // Remember the network for "connect at launch" (#63): only its ID, never credentials.
        didSet { if status.isStarted, let id = status.profileID, id != lastConnectedID { lastConnectedID = id } }
    }
    @Published var problem: BackendProblem?
    @Published var busy = false
    @Published var importing = false
    @Published var candidate: NetworkProfile?
    @Published var importName = ""
    @Published var importPath: String?
    @Published var replacementID: String?
    @Published var showDetails = false
    @Published var renameTarget: NetworkProfile?
    private var authorizationInProgress = false
    private var files: [String: String] = [:]
    private var timer: Timer?
    /// Live kernel log polling, running only while the logs page is open.
    private var logTimer: Timer?
    private var refreshingLogs = false
    private var sampleTimer: Timer?
    private var sampling = false
    private let client: any AppBackend
    private let now: () -> Date
    private let wait: (TimeInterval) async throws -> Void
    private var servicesEnabled = false
    private var foregroundObserver: NSObjectProtocol?
    private var lastNotificationSync = Date.distantPast
    var selected: NetworkProfile? { profiles.first { $0.id == selectedID } }
    var active: NetworkProfile? { profiles.first { $0.id == status.profileID } }
    var isCurrentStarted: Bool { status.isStarted && status.profileID == selectedID }
    /// Status item state (#65): busy or recovering first, then connected, then anything needing attention.
    var menuIconState: MenuIconState {
        if connectionBusy || (recoveryProfileID != nil && !recoveryText.isEmpty) { return .connecting }
        if status.isStarted { return .connected }
        if status.state == "failed" || problem != nil || (!profiles.isEmpty && (!authorization.available || authorization.updateRequired == true)) {
            return .attention
        }
        return .disconnected
    }
    /// Menu network switch: connects `id`, disconnecting the current network first.
    /// Returns false when the connection component needs the main window (never prompts here).
    @discardableResult func switchNetwork(to id: String) async -> Bool {
        guard !busy, !shuttingDown, profiles.contains(where: { $0.id == id }) else { return true }
        if status.isStarted && status.profileID == id { return true }
        selectedID = id
        guard authorization.available, authorization.updateRequired != true else { return false }
        await connectSelected()
        return true
    }
    /// The menu shows the network its primary action targets: the active one while started, else the selection.
    var menuProfile: NetworkProfile? { status.isStarted ? (active ?? selected) : selected }
    var connectionActionTitle: String {
        isCurrentStarted ? "断开连接" : !authorization.available ? "启用连接后台" : status.isStarted ? "切换并连接" : "连接网络"
    }
    var menuActionTitle: String {
        status.isStarted ? "断开连接" : !authorization.available ? "启用连接后台" : "连接所选网络"
    }
    var statusText: String {
        if busy { return "正在处理" }
        if status.isStarted { return "隧道已启动" }
        if status.state == "failed" { return "连接未完成" }
        return profiles.isEmpty ? "等待导入" : "未连接"
    }
    /// Isolated model: no polling, environment observers, notifications or transport startup.
    init(client: any AppBackend, now: @escaping () -> Date = Date.init,
         wait: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }, notifications: CertificateNotifications? = nil,
         defaults: UserDefaults? = nil, loginItem: (any LoginItemControl)? = nil,
         updater: (any SoftwareUpdating)? = nil) {
        self.client = client; self.now = now; self.wait = wait; self.updater = updater
        notificationsAllowed = false; injectedNotifications = notifications
        // Tests and previews get a private, emptied domain and never the system login item.
        self.defaults = defaults ?? {
            let ephemeral = UserDefaults(suiteName: "net.nebula.gui.ephemeral")!
            ephemeral.removePersistentDomain(forName: "net.nebula.gui.ephemeral")
            return ephemeral
        }()
        self.loginItem = loginItem ?? UnavailableLoginItem()
        autoConnect = self.defaults.bool(forKey: Self.autoConnectKey)
        automaticUpdateChecks = self.defaults.object(forKey: Self.automaticUpdatesKey) as? Bool ?? true
        loginItemState = self.loginItem.state
        reconcileLoginItem()
    }
    convenience init() {
        let arguments = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = argument("--data-dir").map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("NebulaGUI", isDirectory: true)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nebula-gui-backend")
        // An isolated --data-dir development run keeps away from real settings and login items.
        let isolated = argument("--data-dir") != nil
        self.init(client: BackendClient(executable: executable, store: store),
                  defaults: isolated ? nil : .standard, loginItem: isolated ? nil : SystemLoginItem(),
                  updater: isolated ? nil : GitHubSoftwareUpdater())
        servicesEnabled = true
        notificationsAllowed = argument("--data-dir") == nil
        notificationsEnabled = certificateNotifications.enabled
        notificationText = notificationsEnabled ? "已开启 30／7／1 天及到期提醒" : "到期提醒未开启"
        environmentMonitor = ConnectionEnvironment { [weak self] event in self?.environmentChanged(event) }
        Task {
            await refresh()
            await autoConnectIfNeeded()
            if let path = argument("--import") { await preview(path: path) }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // The user may have approved the login item in System Settings meanwhile.
            Task { @MainActor in self?.refreshLoginItem(); await self?.refreshNotifications() }
        }
        startPolling()
        startUpdateChecks()
    }
    private func startPolling() {
        guard servicesEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, !self.shuttingDown, !self.sleeping else { return }
                await self.refreshStatus()
                if Date().timeIntervalSince(self.lastNotificationSync) >= 300 { await self.refreshNotifications() }
            }
        }
    }
    func refresh() async {
        guard !shuttingDown else { return }
        do {
            let listed = try await client.send(BackendRequest(method: "list"), as: [NetworkProfile].self)
            guard !shuttingDown else { return }
            profiles = listed; profilesLoaded = true
            if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id }
            await refreshStatus()
            guard !shuttingDown else { return }
            await refreshNotifications()
        } catch { setProblem(error) }
    }
    func refreshStatus() async {
        guard !refreshingStatus, !shuttingDown, !sleeping else { return }
        refreshingStatus = true
        let generation = recovery.generation
        defer { refreshingStatus = false; evaluateRecovery() }
        do {
            let snapshot = try await client.send(BackendRequest(method: "status"), as: ConnectionStatus.self)
            guard generation == recovery.generation, !shuttingDown else { return }
            // Publish only real changes: every assignment re-renders the whole window.
            if !snapshot.sameObservation(as: status) { status = snapshot }
            if latency.session != nil && latency.session != latencySession { latency.reset(); latencyExpanded = [] }
            let currentAuthorization = try await client.send(BackendRequest(method: "authorization"), as: AuthorizationState.self)
            guard generation == recovery.generation, !shuttingDown else { return }
            if currentAuthorization != authorization { authorization = currentAuthorization }
            if showDetails {
                let currentEvents = try await client.send(BackendRequest(method: "events"), as: [ConnectionEvent].self)
                if currentEvents != events { events = currentEvents }
            }
            if snapshot.isStarted, let code = problem?.code, transientCodes.contains(code) { problem = nil }
            // The private store opened once the other Nebula quit or its permissions were fixed (#84).
            if let code = problem?.code, ["store_in_use", "store_unavailable"].contains(code) {
                problem = nil
                if !profilesLoaded { Task { await self.refresh() } }
            }
        } catch {
            guard generation == recovery.generation, !shuttingDown else { return }
            setProblem(error)
            status = ConnectionStatus(state: "failed", profileID: status.profileID, error: problem, peers: [], startedAt: status.startedAt)
        }
    }
    /// Empty-state text, or nil when entries exist. An older helper relays no logs
    /// but the backend cannot tell an empty buffer from a missing capability,
    /// so a pending component upgrade explains an empty page.
    var kernelLogNotice: String? {
        guard let page = kernelLogs else { return "正在读取…" }
        guard page.entries.isEmpty else { return nil }
        if authorization.updateRequired == true { return "当前连接后台不提供内核日志，升级连接后台后可查看。" }
        if !page.available { return "当前连接后台不提供内核日志。" }
        return "暂无内核日志。连接网络后，Nebula 的启动、握手和错误信息会显示在这里。"
    }
    /// While the logs page is open, kernel logs are fetched at once and then every second.
    func showLogs(_ visible: Bool) {
        logsVisible = visible
        startLogPolling()
    }
    private func startLogPolling() {
        logTimer?.invalidate(); logTimer = nil
        guard logsVisible, servicesEnabled, !sleeping, !shuttingDown else { return }
        Task { await refreshLogs() }
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshLogs() }
        }
    }
    /// Identifies one connection: a reconnect or network switch starts a new history.
    var latencySession: String? { status.isStarted ? "\(status.profileID ?? "")|\(status.startedAt ?? "")" : nil }
    func showNodes(_ visible: Bool) {
        nodesVisible = visible
        startSampling()
    }
    func showMenu(_ visible: Bool) {
        menuVisible = visible
        startSampling()
    }
    /// Sampling runs while either the nodes page or the menu bar panel is visible.
    private var samplingWanted: Bool { nodesVisible || menuVisible }
    private func startSampling() {
        sampleTimer?.invalidate(); sampleTimer = nil
        guard samplingWanted, servicesEnabled, !sleeping, !shuttingDown else { return }
        Task { await sampleLatency() }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sampleLatency() }
        }
    }
    /// One ICMP echo per active peer address. Failures are skipped silently: the
    /// connection state reports problems, not the monitor.
    func sampleLatency() async {
        guard samplingWanted, !shuttingDown, !sleeping, !sampling, let session = latencySession else { return }
        let targets = LatencyTargets.of(status.peers)
        guard !targets.isEmpty else { return }
        sampling = true; defer { sampling = false }
        guard let round = try? await client.send(BackendRequest(method: "sample", addresses: targets), as: LatencyRound.self),
              latencySession == session, !shuttingDown else { return } // A changed session never receives old results.
        latency.record(round, session: session)
    }
    /// A failed log read keeps the previous page; it must not mark the connection as failed.
    func refreshLogs() async {
        guard logsVisible, !shuttingDown, !sleeping, !refreshingLogs else { return }
        refreshingLogs = true; defer { refreshingLogs = false }
        if let page = try? await client.send(BackendRequest(method: "logs"), as: KernelLogPage.self), page != kernelLogs { kernelLogs = page }
    }
    func chooseImport(replacing: String? = nil) {
        guard !shuttingDown, renameTarget == nil else { return }
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
        guard !busy, !shuttingDown else { return }
        busy = true; defer { busy = false }
        if !preservingOverrides { files = [:] }
        importing = true; candidate = nil; problem = nil; importPath = path
        do {
            let profile = try await client.send(BackendRequest(method: "preview", path: path, files: files), as: NetworkProfile.self)
            guard !shuttingDown else { return }
            candidate = profile
            importName = profiles.first(where: { $0.id == replacementID })?.name ?? profile.name
        } catch { setProblem(error) }
    }
    func supplementFile() {
        guard !shuttingDown else { return }
        guard let role = problem?.field?.split(separator: ".").last.map(String.init), ["ca", "cert", "key"].contains(role) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "补选 \(role) 文件，原始 config.yaml 不会被修改。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.files[role] = url.path; if let path = self.importPath { await self.preview(path: path, preservingOverrides: true) } }
        }
    }
    func confirmImport() async {
        guard let candidate, let path = importPath, !busy, !shuttingDown else { return }
        busy = true; defer { busy = false }
        do {
            let saved = try await client.send(BackendRequest(method: "import", path: path, profileID: replacementID,
                name: importName, digest: candidate.digest, files: files), as: NetworkProfile.self)
            guard !shuttingDown else { return }
            importing = false; self.candidate = nil; problem = nil
            await refresh(); selectedID = saved.id
        } catch { setProblem(error) }
    }
    func refreshLoginItem() { loginItemState = loginItem.state }
    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemNotice = nil
        defaults.set(enabled, forKey: Self.launchAtLoginKey)
        do { try enabled ? loginItem.register() : loginItem.unregister() }
        catch { loginItemNotice = enabled ? "未能设置为登录时打开，请在系统设置的“登录项”中手动添加 Nebula。" : "未能取消登录时打开，请在系统设置的“登录项”中移除 Nebula。" }
        loginItemState = loginItem.state
    }
    func openLoginItemSettings() { loginItem.openSettings() }
    /// Ad-hoc signed builds get a new identity (cdhash) on every update, so the system
    /// treats each build as a different, unregistered app (#67). Carry the user's choice
    /// over by registering the current build; earlier builds' entries cannot be removed
    /// from here and stay in System Settings until Developer ID signing (#8).
    private func reconcileLoginItem() {
        guard defaults.object(forKey: Self.launchAtLoginKey) != nil else {
            // Migration from builds that only had the system's record: registered means "on".
            if loginItemState == .enabled || loginItemState == .requiresApproval { defaults.set(true, forKey: Self.launchAtLoginKey) }
            return
        }
        guard defaults.bool(forKey: Self.launchAtLoginKey), loginItemState == .disabled else { return }
        do { try loginItem.register() }
        catch { loginItemNotice = "未能为当前版本恢复“登录时打开”，请关闭后重新打开此开关。" }
        loginItemState = loginItem.state
    }
    /// Runs once per launch. Never opens the administrator dialog: if the connection
    /// component is missing or outdated it explains why and leaves connecting to the user.
    /// A failed attempt is retried by automatic recovery like any user connection.
    func autoConnectIfNeeded() async {
        guard !autoConnectAttempted, !shuttingDown else { return }
        autoConnectAttempted = true
        guard autoConnect, !status.isStarted, let id = lastConnectedID else { return }
        guard profiles.contains(where: { $0.id == id }) else {
            problem = BackendProblem(code: "auto_connect_skipped", message: "上次使用的网络已移除，未自动连接。"); return
        }
        guard authorization.available, authorization.updateRequired != true else {
            problem = BackendProblem(code: "auto_connect_skipped", message: "连接后台未启用或需要升级，未自动连接。处理后可手动连接。"); return
        }
        selectedID = id
        await connectSelected()
    }
    func connectSelected() async {
        guard !busy, !shuttingDown else { return }
        if isCurrentStarted { await disconnect(); return }
        if !authorization.available { upgradingAuthorization = false; showAuthorizationReview = true; return }
        guard let selected else { return }
        recoveryTask?.cancel(); recoveryTask = nil
        let generation = recovery.userConnect(selected.id)
        busy = true; connectionBusy = true; problem = nil
        defer { if generation == recovery.generation { busy = false; connectionBusy = false; evaluateRecovery() } }
        do {
            if status.state == "failed", transientCodes.contains(status.error?.code ?? "") {
                let cleared = try await client.recover()
                guard generation == recovery.generation, !shuttingDown else { return }
                status = cleared
            } else if status.profileID != nil {
                let cleared = try await client.send(BackendRequest(method: "disconnect"), as: ConnectionStatus.self)
                guard generation == recovery.generation, !shuttingDown else { return }
                status = cleared
            }
            let connected = try await client.send(BackendRequest(method: "connect", profileID: selected.id), as: ConnectionStatus.self)
            guard generation == recovery.generation, !shuttingDown else { return }
            status = connected; recovery.observedStarted(at: now())
        } catch {
            guard generation == recovery.generation, !shuttingDown else { return }
            setProblem(error)
            let uncertainID = ["cleanup_incomplete", "backend_stopped", "backend_unavailable"].contains(problem?.code ?? "") ? selected.id : nil
            status = ConnectionStatus(state: "failed", profileID: status.profileID ?? uncertainID, error: problem, peers: [])
        }
    }
    func disconnect() async {
        guard (!busy || connectionBusy), !shuttingDown else { return }
        let generation = recovery.userDisconnect()
        recoveryTask?.cancel(); recoveryTask = nil; recoveryText = ""
        busy = true; connectionBusy = true
        defer { if generation == recovery.generation { busy = false; connectionBusy = false } }
        do {
            let disconnected = try await client.send(BackendRequest(method: "disconnect"), as: ConnectionStatus.self)
            guard generation == recovery.generation else { return }
            status = disconnected; problem = nil
        } catch {
            guard generation == recovery.generation else { return }
            setProblem(error)
            status = ConnectionStatus(state: "failed", profileID: status.profileID, error: problem, peers: [])
        }
    }
    func chooseRename() {
        guard !busy, !shuttingDown, !importing, !showAuthorizationReview, let selected else { return }
        problem = nil; renameTarget = selected
    }
    func renameProfile(_ id: String, to name: String) async {
        guard !busy, !shuttingDown else { return }
        if let message = ProfileNameRules.validationMessage(name) {
            problem = BackendProblem(code: "invalid_name", message: message, field: "name"); return
        }
        busy = true; defer { busy = false }
        do {
            let renamed = try await client.send(BackendRequest(method: "rename", profileID: id, name: ProfileNameRules.normalized(name)), as: NetworkProfile.self)
            guard !shuttingDown else { return }
            if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = renamed }
            renameTarget = nil; problem = nil
        } catch { if !shuttingDown { setProblem(error) } }
    }
    func copyNodeAddress(_ address: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    func removeSelected() async {
        guard let selected, !busy, !shuttingDown else { return }
        let alert = NSAlert(); alert.messageText = "移除 \(selected.name)？"
        alert.informativeText = "将删除应用保存的配置与凭据副本，原始文件保持不变。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; defer { busy = false }
        do { _ = try await client.send(BackendRequest(method: "remove", profileID: selected.id), as: Acknowledgement.self); await refresh() }
        catch {
            let issue = error
            if (issue as? BackendProblem)?.code == "profile_cleanup_pending" { await refresh() }
            setProblem(issue)
        }
    }
    func rollbackSelected() async {
        guard let selected, !busy, !shuttingDown else { return }; busy = true; defer { busy = false }
        do { _ = try await client.send(BackendRequest(method: "rollback", profileID: selected.id), as: NetworkProfile.self); await refresh() }
        catch { setProblem(error) }
    }
    func exportDiagnostics() async {
        guard !shuttingDown else { return }
        // Only the backend's fixed diagnostic schema is exported, never the original YAML.
        struct Event: Codable, Sendable { let time: String; let code: String }
        struct Diagnostic: Codable, Sendable {
            let schema: Int; let kernelRevision: String; let state: String
            let profileCount: Int; let knownPeerCount: Int; let events: [Event]; let generatedAt: String
        }
        do {
            let data = try await client.send(BackendRequest(method: "diagnostics"), as: Diagnostic.self)
            guard !shuttingDown else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "nebula-diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.message = "仅包含版本、状态、数量和事件代码；不包含地址、设备名、配置或密钥。"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch { setProblem(error) }
    }
    func manageAuthorization(removing: Bool) async {
        guard !busy, !status.isStarted, !shuttingDown else { return }
        busy = true; authorizationInProgress = true; problem = nil; showAuthorizationReview = false
        recoveryTask?.cancel(); recoveryTask = nil
        if removing { recovery.userDisconnect(); recoveryText = "" }
        defer { busy = false; authorizationInProgress = false; evaluateRecovery() }
        do {
            let plan = removing ? AuthorizationPlan.uninstall() : try AuthorizationPlan.install(bundle: Bundle.main.bundleURL, uid: getuid(), upgrading: upgradingAuthorization)
            try await AuthorizationRunner.execute(plan)
            if removing {
                for attempt in 0..<20 {
                    do { try await client.completeAuthorizedRemoval(); break }
                    catch { if attempt == 19 { throw error }; try await Task.sleep(nanoseconds: 200_000_000) }
                }
                status = .disconnected
            } else {
                status = try await client.recover()
            }
            for _ in 0..<20 {
                authorization = try await client.send(BackendRequest(method: "authorization"), as: AuthorizationState.self)
                if authorization.available != removing && (removing || authorization.updateRequired != true) { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if authorization.available == removing || (!removing && authorization.updateRequired == true) {
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
        shuttingDown = true
        recovery.userDisconnect(); recoveryTask?.cancel(); recoveryTask = nil; networkTask?.cancel(); recoveryText = ""
        timer?.invalidate(); logTimer?.invalidate(); logTimer = nil; sampleTimer?.invalidate(); sampleTimer = nil
        updateTimer?.invalidate(); updateTimer = nil
        do {
            try await client.shutdown(permanently: true); environmentMonitor?.stop()
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver); self.foregroundObserver = nil }
            return true
        }
        catch { shuttingDown = false; busy = false; connectionBusy = false; setProblem(error); startPolling(); startUpdateChecks(); return false }
    }
    func setProblem(_ error: Error) {
        problem = error as? BackendProblem ?? BackendProblem(code: "operation_failed", message: "操作未完成，请重试。")
    }
}


extension AppModel {
    private var transientCodes: [String] { ["backend_stopped", "backend_unavailable", "cleanup_incomplete", "cleanup_pending", "authorization_required", "rebind_failed"] }
    /// Runs after every 3 s poll; assigning an unchanged @Published value still re-renders the window.
    private func showRecovery(_ text: String) { if recoveryText != text { recoveryText = text } }
    private func evaluateRecovery() {
        guard !shuttingDown else { return }
        if status.isStarted {
            recovery.observedStarted(at: now()); showRecovery(""); return
        }
        guard recovery.desiredProfileID != nil, automaticRecovery else { showRecovery(""); return }
        if sleeping { showRecovery("电脑睡眠期间暂停恢复"); return }
        if !networkAvailable { showRecovery("系统网络不可用，恢复已暂停"); return }
        guard !busy, !shuttingDown else { return }
        let code = status.error?.code ?? problem?.code ?? "backend_stopped"
        guard let retry = recovery.schedule(code: code, at: now()) else {
            showRecovery(recovery.attempts >= 5 ? "自动恢复已暂停，请手动重新连接" : "请处理提示后手动重新连接")
            return
        }
        showRecovery("等待自动恢复，第 \(recovery.attempts + 1)／5 次")
        guard recoveryTask == nil else { return }
        let scheduledGeneration = recovery.generation
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0, retry.timeIntervalSince(self.now()))
            do { try await self.wait(delay) } catch { return }
            guard !Task.isCancelled, self.recovery.generation == scheduledGeneration else { return }
            await self.attemptRecovery()
        }
    }
    private func attemptRecovery() async {
        guard !busy, !shuttingDown, let attempt = recovery.beginAttempt(at: now()) else { recoveryTask = nil; return }
        busy = true; connectionBusy = true; recoveryText = "正在恢复连接，第 \(attempt.number)／5 次"
        defer {
            if attempt.generation == recovery.generation { recoveryTask = nil; busy = false; connectionBusy = false; evaluateRecovery() }
        }
        do {
            let cleared = try await client.recover()
            guard recovery.accepts(attempt), !shuttingDown, !sleeping, networkAvailable else { return }
            status = cleared
            let connected = try await client.send(BackendRequest(method: "connect", profileID: attempt.profileID), as: ConnectionStatus.self)
            guard recovery.accepts(attempt), !shuttingDown else { return }
            status = connected; problem = nil; recovery.observedStarted(at: now())
        } catch {
            guard recovery.accepts(attempt), !shuttingDown else { return }
            setProblem(error)
            status = ConnectionStatus(state: "failed", profileID: status.profileID, error: problem, peers: [])
        }
    }
    func environmentChanged(_ event: ConnectionEnvironment.Event) {
        guard !shuttingDown else { return }
        switch event {
        case .sleep: sleeping = true; timer?.invalidate(); logTimer?.invalidate(); logTimer = nil; sampleTimer?.invalidate(); sampleTimer = nil
        case .wake: sleeping = false; startPolling(); startLogPolling(); startSampling()
        case .network(let available): networkAvailable = available
        }
        recovery.environment(sleeping: sleeping, networkAvailable: networkAvailable)
        recoveryTask?.cancel(); recoveryTask = nil; networkTask?.cancel()
        if sleeping || !networkAvailable { evaluateRecovery(); return }
        networkTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.wait(1.5) } catch { return }
            guard !Task.isCancelled, !self.shuttingDown, !self.busy else { return }
            await self.refreshStatus()
            guard self.status.isStarted, self.authorization.supportsRecovery, !self.busy, !self.shuttingDown else { return }
            let generation = self.recovery.generation
            do {
                let snapshot = try await self.client.send(BackendRequest(method: "rebind"), as: ConnectionStatus.self)
                guard generation == self.recovery.generation, !self.shuttingDown else { return }
                self.status = snapshot
            } catch {
                guard generation == self.recovery.generation, !self.shuttingDown else { return }
                self.setProblem(error); await self.refreshStatus()
            }
        }
    }
    /// Background reconciliation: retried every 5 minutes even on failure, reported locally
    /// so it never replaces an unrelated connection problem.
    func refreshNotifications() async {
        guard !shuttingDown, profilesLoaded else { return }
        lastNotificationSync = Date()
        do {
            try await certificateNotifications.synchronize(profiles)
            guard !shuttingDown else { return }
            notificationsEnabled = certificateNotifications.enabled
            notificationText = !notificationsEnabled ? "到期提醒未开启" : certificateNotifications.permissionAllowed ? "已开启 30／7／1 天及到期提醒" : "系统未允许通知，请到系统设置允许 Nebula 通知"
        } catch { if !shuttingDown { notificationText = "提醒补排未完成，将在 5 分钟内自动重试" } }
    }
    func sendTestNotification() async {
        guard !notificationsBusy, !shuttingDown else { return }
        notificationsBusy = true
        defer { notificationsBusy = false }
        do {
            try await certificateNotifications.sendTest()
            guard !shuttingDown else { return }
            notificationText = "测试通知已提交，显示方式由系统通知设置决定"
        } catch { if !shuttingDown { notificationText = notificationFailure(error) } }
    }
    func setNotifications(_ enabled: Bool) async {
        guard !notificationsBusy, !shuttingDown else { return }
        notificationsBusy = true
        defer { notificationsBusy = false }
        do {
            if enabled {
                notificationsEnabled = try await certificateNotifications.enable()
                notificationText = notificationsEnabled ? "已开启 30／7／1 天及到期提醒" : "系统未允许通知，仍可在 App 内查看有效期"
                if notificationsEnabled && profilesLoaded { try await certificateNotifications.synchronize(profiles) }
            } else {
                await certificateNotifications.disable(); notificationsEnabled = false; notificationText = "到期提醒未开启"
            }
        } catch { if !shuttingDown { notificationText = notificationFailure(error) } }
    }
    /// Shown in the notification section only; the next refresh replaces it with the system state.
    private func notificationFailure(_ error: Error) -> String {
        (error as? BackendProblem)?.message ?? "通知操作未完成，请重试。"
    }
}

/// Software update (#69). Checking never touches the connection; installing replaces only
/// the App and then quits, which disconnects like any other quit.
enum UpdateState: Equatable {
    case idle, checking, upToDate
    case available(AvailableUpdate)
    case installing(AvailableUpdate)
    case installed(AvailableUpdate)
    /// The update, when known, stays reachable through its release page.
    case failed(String, AvailableUpdate?)
}

extension AppModel {
    var updatesSupported: Bool { updater?.currentVersion != nil }
    var currentVersionText: String { updater?.currentVersion?.description ?? "开发版本" }
    var availableUpdate: AvailableUpdate? {
        switch updateState {
        case .available(let update), .installing(let update), .installed(let update): return update
        case .failed(_, let update): return update
        default: return nil
        }
    }
    var updateInProgress: Bool {
        switch updateState { case .checking, .installing, .installed: return true; default: return false }
    }
    var lastUpdateCheck: Date? { defaults.object(forKey: Self.lastUpdateCheckKey) as? Date }

    /// At launch (after a short delay) and hourly; a check runs at most once a day.
    fileprivate func startUpdateChecks() {
        guard servicesEnabled, updater != nil else { return }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdatesIfDue() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.checkForUpdatesIfDue()
        }
    }
    func checkForUpdatesIfDue() async {
        guard automaticUpdateChecks else { return }
        if let last = lastUpdateCheck, now().timeIntervalSince(last) < 24 * 3600 { return }
        await checkForUpdates()
    }
    func checkForUpdates() async {
        guard let updater, let current = updater.currentVersion, !updateInProgress, !shuttingDown else { return }
        updateState = .checking
        do {
            let found = try await updater.latest(after: current)
            guard !shuttingDown else { return }
            defaults.set(now(), forKey: Self.lastUpdateCheckKey)
            updateState = found.map(UpdateState.available) ?? .upToDate
        } catch {
            guard !shuttingDown else { return }
            updateState = .failed(updateMessage(error), nil)
        }
    }
    /// Called after the user confirmed that the connection will be interrupted.
    func installUpdate() async {
        guard let updater, let update = availableUpdate, update.installable, !updateInProgress, !shuttingDown else { return }
        guard !busy, !authorizationInProgress else {
            updateState = .failed("请等待当前操作完成后再安装更新。", update); return
        }
        updateState = .installing(update)
        do {
            let staged = try await updater.prepare(update)
            guard !shuttingDown else { return }
            try updater.install(staged)
            updateState = .installed(update)
            updater.restart()
        } catch {
            guard !shuttingDown else { return }
            updateState = .failed(updateMessage(error), update)
        }
    }
    func openUpdatePage() {
        guard let updater, let update = availableUpdate else { return }
        updater.openPage(update)
    }
    private func updateMessage(_ error: Error) -> String {
        (error as? BackendProblem)?.message ?? "更新未完成，请稍后重试。"
    }
}
