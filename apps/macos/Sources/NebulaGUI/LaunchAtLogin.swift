import AppKit
import ServiceManagement
import NebulaClient

/// Whether macOS opens Nebula at login (#63).
enum LoginItemState: Equatable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings › General › Login Items.
    case requiresApproval
    /// Not manageable in this build or context (previews, tests, unsupported install).
    case unavailable
}

@MainActor protocol LoginItemControl {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

/// The app itself as a login item via SMAppService (macOS 13+). No helper or daemon is involved.
struct SystemLoginItem: LoginItemControl {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        default: return .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Used by tests and the UI preview: never touches the system's login items.
struct UnavailableLoginItem: LoginItemControl {
    var state: LoginItemState { .unavailable }
    func register() throws { throw BackendProblem(code: "preview_only", message: "合成预览与测试不修改系统登录项。") }
    func unregister() throws { throw BackendProblem(code: "preview_only", message: "合成预览与测试不修改系统登录项。") }
    func openSettings() {}
}
