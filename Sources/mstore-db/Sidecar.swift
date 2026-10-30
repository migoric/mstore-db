import Foundation

/// 与 mstore sidecar 的 stdio NDJSON 通道。
///
/// 协议：一行一个请求、一行一个响应；请求带自增 id，响应回填同一个 id。
/// 全部同步读写（调用方放在后台队列），这样 Swift 侧不需要维护状态机。
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
    var pid: Int32 { process.processIdentifier }

    /// node 与 cli.ts 的路径：环境变量优先，方便不重建 App 就换内核
    static func locateRuntime() -> (node: String, cli: String)? {
        let env = ProcessInfo.processInfo.environment
        let node = env["MSTORE_NODE"]
            ?? ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
        var candidates: [String] = []
        if let cli = env["MSTORE_CLI"] { candidates.append(cli) }
        candidates.append(FileManager.default.currentDirectoryPath + "/../mstore/cli.ts")
        candidates.append(FileManager.default.currentDirectoryPath + "/cli.ts")
        candidates.append(NSHomeDirectory() + "/Documents/projects/mstore/cli.ts")
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return (node, c)
        }
        return nil
    }

    func start(dbPath: String) throws {
        guard let rt = Self.locateRuntime() else {
            throw SidecarError.runtimeNotFound
        }
        process.executableURL = URL(fileURLWithPath: rt.node)
        process.arguments = [rt.cli, "serve", dbPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // 第一行是 hello，带 pid / crc 实现 / 初始统计
        if let line = readLine(), let obj = line["hello"] as? [String: Any] {
            hello = obj
        }
    }

    func stop() {
        if process.isRunning {
            _ = send(["op": "quit"])
            process.terminate()
        }
    }

    // MARK: - 请求

    func send(_ body: [String: Any]) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return nil }
        var req = body
        let id = nextId
        nextId += 1
        req["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        var line = data
        line.append(0x0a)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            return nil
        }
        // 读到同 id 的响应为止（忽略中间的推送帧）
        while let resp = readLine() {
            if let rid = resp["id"] as? Int, rid == id { return resp }
        }
        return nil
    }

    private func readLine() -> [String: Any]? {
        let handle = stdoutPipe.fileHandleForReading
        while true {
            if let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if lineData.isEmpty { continue }
                return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
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
