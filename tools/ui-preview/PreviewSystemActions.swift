import NebulaClient

/// These types replace production OS adapters only in the preview executable.
enum AuthorizationRunner {
    static func execute(_ plan: AuthorizationPlan) async throws {
        throw BackendProblem(code: "preview_only", message: "合成预览不安装、升级或移除系统组件。")
    }
}

@MainActor final class CertificateNotifications {
    init(allowDelivery: Bool = false) {}
    var enabled: Bool { false }
    var permissionAllowed: Bool { false }
    func enable() async throws -> Bool {
        throw BackendProblem(code: "preview_only", message: "合成预览不修改系统通知或偏好设置。")
    }
    func sendTest() async throws {
        throw BackendProblem(code: "preview_only", message: "合成预览不发送系统通知。")
    }
    func disable() async {}
    func synchronize(_ profiles: [NetworkProfile]) async throws {}
}
