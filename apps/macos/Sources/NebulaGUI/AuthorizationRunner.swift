import Foundation
import NebulaClient

/// Authorization happens in macOS's own administrator dialog, never in an app text field.
enum AuthorizationRunner {
    static func execute(_ plan: AuthorizationPlan) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); let input = Pipe(); let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.standardInput = input; process.standardOutput = FileHandle.nullDevice
                process.standardError = errors
                do {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: Data(plan.appleScript.utf8))
                    try input.fileHandleForWriting.close()
                    // Drain before waiting; even an unexpected verbose error must not fill the pipe.
                    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { continuation.resume(); return }
                    let cancelled = String(data: errorData, encoding: .utf8)?.contains("(-128)") == true
                    continuation.resume(throwing: BackendProblem(code: cancelled ? "authorization_cancelled" : "authorization_failed",
                        message: cancelled ? "你已取消管理员授权，尚未启用连接后台。" : "后台安装、升级或移除失败。升级会尝试恢复旧组件；请刷新状态后检查。"))
                } catch {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    continuation.resume(throwing: BackendProblem(code: "authorization_failed", message: "无法打开 macOS 管理员授权窗口。"))
                }
            }
        }
    }
}
