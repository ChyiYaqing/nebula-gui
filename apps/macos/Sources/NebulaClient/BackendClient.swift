import Foundation
import Darwin

private final class InterruptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var forced = false
    func markForced() { lock.lock(); forced = true; lock.unlock() }
    var wasForced: Bool { lock.lock(); defer { lock.unlock() }; return forced }
}

/// All mutable transport state belongs to queue; no TCP listener or shared socket.
public final class BackendClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.nebula.gui.backend", qos: .userInitiated)
    private let executable: URL
    private let store: URL
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var exitSignal: DispatchSemaphore?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var cleanupWarning: BackendProblem?
    public init(executable: URL, store: URL) { self.executable = executable; self.store = store; self.requestTimeout = 20 }
    init(executable: URL, store: URL, requestTimeout: TimeInterval) {
        self.executable = executable; self.store = store; self.requestTimeout = requestTimeout
    }

    public func send<T: Decodable & Sendable>(_ request: BackendRequest, as type: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let interruption = InterruptionState()
                do {
                    if let warning = self.cleanupWarning { throw warning }
                    try self.startIfNeeded()
                    guard let process = self.process, let input = self.input else {
                        throw BackendProblem(code: "backend_unavailable", message: "连接后台不可用。")
                    }
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    let fallback = DispatchWorkItem { if process.isRunning { interruption.markForced(); Darwin.kill(process.processIdentifier, SIGKILL) } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.requestTimeout, execute: timeout)
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.requestTimeout + min(3, max(0.1, self.requestTimeout)), execute: fallback)
                    defer { timeout.cancel(); fallback.cancel() }
                    var body = try JSONEncoder().encode(request); body.append(0x0a)
                    try input.write(contentsOf: body)
                    let line = try self.readLine()
                    continuation.resume(returning: try Wire.decode(type, from: line, requestID: request.id))
                } catch {
                    if interruption.wasForced {
                        let warning = BackendProblem(code: "cleanup_incomplete", message: "后台操作超时且已被强制停止，无法确认隧道清理。请检查系统网络状态并重启应用。")
                        self.cleanupWarning = warning
                        try? self.stopChild()
                        continuation.resume(throwing: warning)
                        return
                    }
                    if let problem = error as? BackendProblem {
                        if ["backend_stopped", "invalid_response", "protocol_mismatch", "response_too_large"].contains(problem.code) { try? self.stopChild() }
                        continuation.resume(throwing: problem)
                    } else {
                        try? self.stopChild()
                        continuation.resume(throwing: BackendProblem(code: "backend_unavailable", message: "无法启动或访问连接后台，请确认应用已完整构建。"))
                    }
                }
            }
        }
    }
    private func readLine() throws -> Data {
        guard let output else { throw BackendProblem(code: "backend_stopped", message: "后台已停止。") }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0a) {
                guard newline < 4 * 1024 * 1024 else { throw BackendProblem(code: "response_too_large", message: "后台响应超过安全限制。") }
                let line = Data(readBuffer[..<newline]); readBuffer.removeSubrange(...newline); return line
            }
            guard readBuffer.count < 4 * 1024 * 1024 else {
                throw BackendProblem(code: "response_too_large", message: "后台响应超过安全限制。")
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BackendProblem(code: "backend_stopped", message: "后台已退出或操作超时，请重试。") }
            readBuffer.append(contentsOf: chunk.prefix(count))
        }
    }
    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        try stopChild()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BackendProblem(code: "backend_missing", message: "应用缺少连接后台，请运行完整构建脚本。")
        }
        let child = Process(); let stdin = Pipe(); let stdout = Pipe(); let exited = DispatchSemaphore(value: 0)
        child.executableURL = executable
        child.arguments = ["serve", "--store", store.path]
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        process = child; exitSignal = exited; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    private func stopChild() throws {
        try? input?.close(); input = nil
        guard let process else { return }
        var forced = false
        if process.isRunning, let exitSignal {
            if exitSignal.wait(timeout: .now() + 5) == .timedOut {
                forced = true; process.terminate()
                if exitSignal.wait(timeout: .now() + 2) == .timedOut {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exitSignal.wait(timeout: .now() + 2)
                }
            }
        }
        let stillRunning = process.isRunning
        try? output?.close(); output = nil; readBuffer = Data()
        if !stillRunning { self.process = nil; self.exitSignal = nil }
        let abnormalExit = !stillRunning && (process.terminationReason != .exit || process.terminationStatus != 0)
        if forced || stillRunning || abnormalExit {
            let warning = BackendProblem(code: "cleanup_incomplete", message: "后台未能正常结束，无法确认隧道清理完成。请检查系统网络状态后再退出。")
            cleanupWarning = warning
            throw warning
        }
    }
    public func shutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.stopChild(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
