import Foundation
import NebulaClient

/// Authorization happens in macOS's own administrator dialog, never in an app text field.
enum AuthorizationRunner {
    static func execute(_ plan: AuthorizationPlan) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); let input = Pipe(); let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.standardInput = input; process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: Data(plan.appleScript.utf8))
                    try input.fileHandleForWriting.close()
                    // Drain the structured result before waiting; raw system errors are discarded.
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw BackendProblem(code: "authorization_failed", message: "管理员操作未完成，请重试；若仍失败，请刷新后台状态后检查。")
                    }
                    try AuthorizationPlan.validateResult(result)
                    continuation.resume()
                } catch {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    continuation.resume(throwing: (error as? BackendProblem) ?? BackendProblem(code: "authorization_failed", message: "无法打开 macOS 管理员授权窗口。"))
                }
            }
        }
    }
}
