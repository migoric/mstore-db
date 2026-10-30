import Foundation

/// 与 mstore sidecar 的 stdio NDJSON 通道。
///
/// 协议：一行一个请求、一行一个响应；请求带自增 id，响应回填同一个 id。
/// 全部同步读写（调用方放在后台队列），这样 Swift 侧不需要维护状态机。
///
/// 对外只暴露 `exchange(Data) -> Data?`：跨 actor 边界传的必须是 Sendable，
/// `[String: Any]` 不是，所以 JSON 的组装/解析全部落在 `StoreClient` 的 actor 内部。
final class Sidecar: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private var nextId = 1
    private(set) var hello: [String: Any] = [:]

    var isRunning: Bool { process.isRunning }

    /// node 与 cli.ts 的路径：环境变量优先，方便不重建 App 就换内核
    static func locateRuntime() -> (node: String, cli: String)? {
        let env = ProcessInfo.processInfo.environment
        let node = env["MSTORE_NODE"]
            ?? ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
        var candidates: [String] = []
        if let cli = env["MSTORE_CLI"] { candidates.append(cli) }
        candidates.append(FileManager.default.currentDirectoryPath + "/../mstore/cli.ts")
        candidates.append(FileManager.default.currentDirectoryPath + "/mstore/cli.ts")
        candidates.append(NSHomeDirectory() + "/Documents/projects/mstore/cli.ts")
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return (node, c)
        }
        return nil
    }

    func start(dbPath: String) throws {
        guard let rt = Self.locateRuntime() else { throw SidecarError.runtimeNotFound }
        var env = ProcessInfo.processInfo.environment
        env["NODE_NO_WARNINGS"] = "1"
        process.environment = env
        process.executableURL = URL(fileURLWithPath: rt.node)
        process.arguments = [rt.cli, "serve", dbPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // 第一行是 hello，带 pid / crc 实现 / 初始统计
        if let raw = readRawLine(),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let h = obj["hello"] as? [String: Any] {
            hello = h
        }
    }

    func stop() {
        if process.isRunning {
            if let quit = try? JSONSerialization.data(withJSONObject: ["op": "quit"]) {
                _ = exchange(quit)
            }
            process.terminate()
        }
    }

    // MARK: - 交换

    /// 发一条请求，返回**原始响应行**（已确认 id 对得上）
    func exchange(_ reqJSON: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return nil }
        guard var obj = (try? JSONSerialization.jsonObject(with: reqJSON)) as? [String: Any] else { return nil }
        let id = nextId
        nextId += 1
        obj["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var line = data
        line.append(0x0a)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            return nil
        }
        // 读到同 id 的响应为止（忽略中间的推送帧）
        while let raw = readRawLine() {
            if let resp = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
               let rid = resp["id"] as? Int, rid == id {
                return raw
            }
        }
        return nil
    }

    private func readRawLine() -> Data? {
        let handle = stdoutPipe.fileHandleForReading
        while true {
            if let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil } // EOF：sidecar 退出
            buffer.append(chunk)
        }
    }
}

enum SidecarError: LocalizedError {
    case runtimeNotFound

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "找不到 mstore 内核。设置 MSTORE_CLI 指向 cli.ts，或把 mstore 放在 ~/Documents/projects/mstore。"
        }
    }
}
