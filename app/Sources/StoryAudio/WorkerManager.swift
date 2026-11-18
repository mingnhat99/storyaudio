import Foundation

/// Quản lý tiến trình worker Python: spawn (nice -n 20), giao thức JSON-lines,
/// khớp request/response theo id, đẩy event/log về app.
final class WorkerManager {
    private(set) var process: Process?
    private var stdinHandle: FileHandle?
    private var writeLock = NSLock()
    private var pendingLock = NSLock()
    private var pending: [Int64: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId: Int64 = 0
    private var outBuffer = Data()
    private var errBuffer = Data()

    var onEvent: (([String: Any]) -> Void)?
    var onLog: ((String) -> Void)?
    /// Worker thoát ngoài ý muốn (crash / bị kill) — app tự restart và nối lại job
    var onUnexpectedExit: (() -> Void)?
    private var expectingExit = false

    private(set) var workspace: URL = URL(fileURLWithPath: "/")
    private(set) var pid: Int32 = 0

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Vòng đời

    /// Spawn: /usr/bin/nice -n 20 <python> tts_worker.py --workspace <ws>
    func start(workspace: URL, python: URL, script: URL, hfEndpoint: String = "") throws {
        stop()
        expectingExit = false
        self.workspace = workspace

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        var args = ["-n", "20", python.path, script.path, "--workspace", workspace.path]
        if !hfEndpoint.isEmpty {
            args += ["--hf-endpoint", hfEndpoint]
        }
        p.arguments = args
        p.currentDirectoryURL = workspace
        // App chạy qua LaunchServices có PATH tối thiểu (/usr/bin:/bin:...) —
        // mở rộng để worker tìm được lame/afconvert của Homebrew khi xuất mp3
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin"
        env["PATH"] = ((env["PATH"] as? String) ?? "/usr/bin:/bin") + ":" + extra
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.failAllPending(WorkerError.workerDied(
                "worker thoát (code \(proc.terminationStatus))"))
            let unexpected = !self.expectingExit
            self.process = nil
            self.stdinHandle = nil
            if unexpected {
                Task { @MainActor in self.onUnexpectedExit?() }
            }
        }

        do {
            try p.run()
        } catch {
            throw WorkerError.cannotStart("Không khởi động được worker: \(error.localizedDescription)")
        }
        process = p
        pid = p.processIdentifier
        stdinHandle = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.readStream(h: h, isStderr: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.readStream(h: h, isStderr: true)
        }
    }

    /// Dừng worker (có chủ đích — không tính là crash)
    func stop() {
        guard let p = process else { return }
        expectingExit = true
        _ = try? sendSync("shutdown")
        stdinHandle?.closeFile()
        stdinHandle = nil
        if p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak p] in
                if p?.isRunning == true { p?.interrupt() }
            }
        }
        process = nil
    }

    // MARK: - Giao thức

    /// Gửi lệnh và chờ phản hồi. timeout = nil: chờ vô hạn (render dài).
    func send(_ cmd: String,
              _ args: [String: Any] = [:],
              timeout: TimeInterval? = nil) async throws -> [String: Any] {
        pendingLock.lock()
        nextId += 1
        let id = nextId
        pendingLock.unlock()

        var payload: [String: Any] = args
        payload["id"] = id
        payload["cmd"] = cmd
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else {
            throw WorkerError.badRequest("Không mã hóa được lệnh \(cmd)")
        }

        return try await withCheckedThrowingContinuation { cont in
            pendingLock.lock()
            pending[id] = cont
            pendingLock.unlock()

            writeLock.lock()
            do {
                try stdinHandle?.write(contentsOf: (line + "\n").data(using: .utf8)!)
            } catch {
                writeLock.unlock()
                failRequest(id, WorkerError.workerDied("stdin đã đóng"))
                return
            }
            writeLock.unlock()

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.failRequest(id, WorkerError.timeout("Lệnh \(cmd) quá \(Int(timeout))s"))
                }
            }
        }
    }

    /// Gửi lệnh không chờ kết quả (cancel, progress...)
    func fireAndForget(_ cmd: String, _ args: [String: Any] = [:]) {
        var payload = args
        payload["cmd"] = cmd
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        writeLock.lock()
        stdinHandle?.write((line + "\n").data(using: .utf8)!)
        writeLock.unlock()
    }

    private func sendSync(_ cmd: String) throws -> Bool {
        guard let handle = stdinHandle else { return false }
        let line = "{\"cmd\":\"\(cmd)\"}\n"
        try handle.write(contentsOf: line.data(using: .utf8)!)
        return true
    }

    // MARK: - Đọc stream

    private func readStream(h: FileHandle, isStderr: Bool) {
        let chunk = h.availableData
        if chunk.isEmpty {
            h.readabilityHandler = nil
            return
        }
        if isStderr {
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n") where !line.isEmpty {
                let s = String(line)
                DispatchQueue.main.async { [weak self] in self?.onLog?(s) }
            }
        } else {
            outBuffer.append(chunk)
            while let nl = outBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = outBuffer[outBuffer.startIndex..<nl]
                outBuffer = Data(outBuffer[outBuffer.index(after: nl)...])
                guard !lineData.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
                else { continue }
                DispatchQueue.main.async { [weak self] in self?.handleMessage(obj) }
            }
        }
    }

    private func handleMessage(_ obj: [String: Any]) {
        if let eventName = obj["event"] as? String {
            onEvent?(obj)
            return
        }
        guard let id = (obj["id"] as? NSNumber)?.int64Value else { return }
        pendingLock.lock()
        guard let cont = pending.removeValue(forKey: id) else {
            pendingLock.unlock()
            return
        }
        pendingLock.unlock()
        cont.resume(returning: obj)
    }

    private func failRequest(_ id: Int64, _ err: Error) {
        pendingLock.lock()
        if let cont = pending.removeValue(forKey: id) {
            pendingLock.unlock()
            cont.resume(throwing: err)
        } else {
            pendingLock.unlock()
        }
    }

    private func failAllPending(_ err: Error) {
        pendingLock.lock()
        let conts = Array(pending.values)
        pending.removeAll()
        pendingLock.unlock()
        for c in conts { c.resume(throwing: err) }
    }
}

enum WorkerError: LocalizedError {
    case cannotStart(String)
    case workerDied(String)
    case timeout(String)
    case badRequest(String)
    case commandFailed(String)
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case .cannotStart(let s), .workerDied(let s), .timeout(let s),
             .badRequest(let s), .commandFailed(let s):
            return s
        case .modelMissing(let id):
            return "Model '\(id)' chưa tải về — hãy tải trong Quản lý model"
        }
    }
}

/// tiện ích: đọc "data" từ phản hồi worker hoặc ném lỗi
func workerData(_ resp: [String: Any], command: String) throws -> [String: Any] {
    if resp["ok"] as? Bool == true {
        return (resp["data"] as? [String: Any]) ?? [:]
    }
    let msg = resp["error"] as? String ?? "lỗi không rõ"
    if msg.hasPrefix("model_missing:") {
        throw WorkerError.modelMissing(String(msg.dropFirst("model_missing:".count)))
    }
    throw WorkerError.commandFailed("\(command): \(msg)")
}
