import Foundation

public struct BackendProblem: Codable, Sendable, Error, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public let field: String?
    public var errorDescription: String? { message }
    public init(code: String, message: String, field: String? = nil) {
        self.code = code; self.message = message; self.field = field
    }
}
public struct NetworkProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let device: String
    public let networks: [String]
    public let groups: [String]?
    public let fingerprint: String
    public let expiresAt: String
    public let importedAt: String
    public let version: String
    public let digest: String
    public var expiration: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
    public var daysRemaining: Int? { expiration.map { Int(floor($0.timeIntervalSinceNow / 86400)) } }
}
public struct KnownPeer: Codable, Sendable, Identifiable {
    public let name: String
    public let addresses: [String]
    public let pending: Bool
    public var id: String { addresses.joined(separator: ",") + String(pending) }
}
public struct ConnectionStatus: Codable, Sendable {
    public var startedAt: String? = nil
    public var observedAt: String? = nil
    public let state: String
    public let profileID: String?
    public let error: BackendProblem?
    public let peers: [KnownPeer]
    public static let disconnected = ConnectionStatus(state: "disconnected", profileID: nil, error: nil, peers: [])
    public var isStarted: Bool { state == "started" }
}
public struct BackendRequest: Encodable, Sendable {
    public let version = 1
    public let id: String
    public let method: String
    public var path: String?
    public var profileID: String?
    public var name: String?
    public var digest: String?
    public var files: [String: String]?
    public init(method: String, path: String? = nil, profileID: String? = nil, name: String? = nil, digest: String? = nil, files: [String: String]? = nil) {
        self.id = UUID().uuidString
        self.method = method; self.path = path; self.profileID = profileID
        self.name = name; self.digest = digest; self.files = files
    }
}
private struct Envelope<T: Decodable>: Decodable {
    let version: Int
    let id: String
    let result: T?
    let error: BackendProblem?
}
public enum Wire {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, requestID: String) throws -> T {
        let response: Envelope<T>
        do { response = try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch { throw BackendProblem(code: "invalid_response", message: "后台响应格式无效，请重新启动应用。") }
        guard response.version == 1, response.id == requestID else {
            throw BackendProblem(code: "protocol_mismatch", message: "后台协议或响应标识不匹配，请重新启动应用。")
        }
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw BackendProblem(code: "invalid_response", message: "后台没有返回操作结果。")
        }
        return result
    }
}
public struct Acknowledgement: Decodable, Sendable { public let removed: Bool }

public struct ConnectionEvent: Decodable, Sendable, Identifiable {
    public let time: String
    public let code: String
    public var id: String { time + code }
    public var title: String {
        switch code {
        case "tunnel_started": return "隧道已启动"
        case "tunnel_stopped": return "已断开连接"
        case "profile_imported": return "配置已保存"
        case "backend_stopped": return "连接后台已停止"
        case "cleanup_incomplete": return "隧道清理未确认"
        case "authorization_required": return "需要管理员授权"
        case "source_changed": return "配置文件已改变"
        default: return "操作未完成"
        }
    }
}
