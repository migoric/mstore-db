import Foundation
import AppKit

struct Row: Identifiable, Hashable {
    let key: String
    let summary: String
    let ts: Int
    var id: String { key }
}

/// 界面状态。所有 UI 更新都回主队列；sidecar 的阻塞读写放在后台队列。
final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var dbPath: String = ""
    @Published var connected = false
    @Published var busy = false
    @Published var statusLine = "未连接"
    @Published var info: [(String, String)] = []
    @Published var rows: [Row] = []
    @Published var selection: Row?
    @Published var detail = ""
    @Published var namespace = "capture"
    @Published var log = ""

    // 业务表（CoW 页表 + 位图索引）：和上面「按 ns 列记录」是两种完全不同的读法
    @Published var bizMode = false
    @Published var filterDept = "" // 空 = 不限
    @Published var filterStatus = ""
    @Published var filterLevelMin = 0
    @Published var filterLevelMax = 8
    @Published var bizMatched = 0
    @Published var bizTookUs: Double = 0
    @Published var bizStatsLine = ""

    /// 命令行带 --biz 时，连上之后直接进业务表视图
    var pendingBizMode = false

    private var sidecar: Sidecar?
    private let work = DispatchQueue(label: "mstore-db.worker", qos: .userInitiated)

    static let namespaces = ["capture", "biz", "agent", "mock"]
    /// 业务表演示库里的枚举值（和 bench/demo.ts 对齐）
    static let depts = ["R&D", "Design", "QA", "Ops", "Sales"]
    static let statuses = ["active", "leave", "gone"]

    // MARK: - 连接

    func open(path: String) {
        sidecar?.stop()
        sidecar = nil
        dbPath = path
        busy = true
        statusLine = "正在启动 sidecar…"
        work.async { [weak self] in
            guard let self else { return }
            let sc = Sidecar()
            do {
                try sc.start(dbPath: path)
                let hello = sc.hello
                let pid = hello["pid"] as? Int ?? 0
                let crc = hello["crc"] as? String ?? "?"
                self.onMain {
                    self.sidecar = sc
                    self.connected = true
                    self.busy = false
                    self.statusLine = "已连接 pid=\(pid) crc=\(crc)"
                    self.refreshInfo()
                    if self.pendingBizMode {
                        self.pendingBizMode = false
                        self.setBizMode(true)
                    } else {
                        self.loadRows()
                    }
                }
            } catch {
                self.onMain {
                    self.busy = false
                    self.statusLine = "连接失败：\(error.localizedDescription)"
                    self.connected = false
                }
            }
        }
    }

    func disconnect() {
        sidecar?.stop()
        sidecar = nil
        connected = false
        statusLine = "已断开"
        info = []
        rows = []
        detail = ""
    }

    // MARK: - 读

    func refreshInfo() {
        guard let sc = sidecar else { return }
        work.async { [weak self] in
            guard let self, let resp = sc.send(["op": "info"]), let r = resp["result"] as? [String: Any] else { return }
            let file = r["file"] as? String ?? self.dbPath
            let logical = (r["bytesLogical"] as? Int ?? 0)
            let segs = r["segs"] as? [String: Any] ?? [:]
            let records = r["records"] as? [String: Any] ?? [:]
            let committer = r["committer"] as? [String: Any] ?? [:]
            var fields: [(String, String)] = []
            fields.append(("文件", (file as NSString).lastPathComponent))
            fields.append(("逻辑大小", String(format: "%.2f MB", Double(logical) / 1_048_576)))
            fields.append(("shell 段", "\(segs["shell"] as? Int ?? 0)"))
            fields.append(("body 区段", "\(segs["body"] as? Int ?? 0)"))
            fields.append(("死段", "\(r["deadSegs"] as? Int ?? 0)"))
            fields.append(("待回收", "\(r["pendingReclaim"] as? Int ?? 0)"))
            let recText = records.keys.sorted().map { "\($0)=\(records[$0] as? Int ?? 0)" }.joined(separator: "  ")
            fields.append(("记录", recText))
            fields.append(("CRC", r["crcImpl"] as? String ?? "?"))
            fields.append(("提交次数", "\(committer["commits"] as? Int ?? 0)"))
            fields.append(("平均批", "\(committer["avgBatch"] as? Double ?? 0)"))
            fields.append(("fsync ewma", String(format: "%.1f ms", committer["fsyncMsEwma"] as? Double ?? 0)))
            self.onMain { self.info = fields }
        }
    }

    func loadRows() {
        guard let sc = sidecar else { return }
        let ns = namespace
        busy = true
        work.async { [weak self] in
            guard let self else { return }
            let resp = sc.send(["op": "list", "ns": ns, "limit": 500])
            let arr = (resp?["result"] as? [[String: Any]]) ?? []
            let rows: [Row] = arr.compactMap { item in
                guard let key = item["key"] as? String else { return nil }
                let ts = item["ts"] as? Int ?? 0
                let summary = Self.summarize(item["value"])
                return Row(key: key, summary: summary, ts: ts)
            }
            self.onMain {
                self.rows = rows
                self.busy = false
                self.statusLine = "\(ns)：\(rows.count) 条"
            }
        }
    }

    func select(_ row: Row) {
        selection = row
        guard let sc = sidecar else { return }
        let ns = namespace
        work.async { [weak self] in
            guard let self else { return }
            var text = ""
            if let resp = sc.send(["op": "get", "ns": ns, "key": row.key]),
               let r = resp["result"] as? [String: Any] {
                if let v = r["value"], let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) {
                    text = String(data: data, encoding: .utf8) ?? ""
                }
                if let b = r["body"] as? [String: Any] {
                    let len = b["l"] as? Int ?? 0
                    text += "\n\nbody: \(String(format: "%.1f KB", Double(len) / 1024))  @off=\(b["o"] as? Int ?? 0) seg=\(b["s"] as? Int ?? 0)"
                }
            }
            self.onMain { self.detail = text }
        }
    }

    /// body 原样读出前 4KB（演示 offset 交接，不 parse 全文）
    func peekBody() {
        guard let sc = sidecar, let sel = selection else { return }
        let ns = namespace
        work.async { [weak self] in
            guard let self else { return }
            let resp = sc.send(["op": "body", "ns": ns, "key": sel.key])
            guard let r = resp?["result"] as? [String: Any],
                  let b64 = r["base64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            let head = data.prefix(4096)
            let text = String(data: head, encoding: .utf8) ?? "<二进制 \(data.count) 字节>"
            self.onMain {
                self.detail = "body 共 \(data.count) 字节，以下为前 \(head.count) 字节（未 parse）：\n\n" + text
            }
        }
    }

    // MARK: - 写 / 维护

    func check() {
        guard let sc = sidecar else { return }
        busy = true
        statusLine = "自检中…"
        work.async { [weak self] in
            guard let self else { return }
            let resp = sc.send(["op": "check"])
            let r = resp?["result"] as? [String: Any] ?? [:]
            let ok = r["ok"] as? Bool ?? false
            let issues = r["issues"] as? [[String: Any]] ?? []
            let text = ok
                ? "自检通过：段 \(r["segs"] as? Int ?? 0)（shell \(r["shellSegs"] as? Int ?? 0) / body \(r["bodySegs"] as? Int ?? 0)），记录 \(r["records"] as? Int ?? 0)"
                : "自检失败：\(issues.count) 个问题\n" + issues.prefix(10).map { "· \($0["where"] ?? "") \($0["detail"] ?? "")" }.joined(separator: "\n")
            self.onMain {
                self.busy = false
                self.statusLine = ok ? "自检通过" : "自检失败"
                self.log = text
                self.refreshInfo()
            }
        }
    }

    func clearNamespace() {
        guard let sc = sidecar else { return }
        let ns = namespace
        busy = true
        work.async { [weak self] in
            guard let self else { return }
            let t0 = Date()
            let resp = sc.send(["op": "clear", "ns": ns])
            let ms = Date().timeIntervalSince(t0) * 1000
            let r = resp?["result"] as? [String: Any] ?? [:]
            let dead = r["deadSegs"] as? Int ?? 0
            let freed = Double(r["freedBytes"] as? Int ?? 0) / 1_048_576
            self.onMain {
                self.busy = false
                self.statusLine = "清空 \(ns)：\(dead) 段，归还 \(String(format: "%.2f", freed)) MB，\(String(format: "%.1f", ms)) ms"
                self.rows = []
                self.detail = ""
                self.refreshInfo()
            }
        }
    }

    func switchNamespace(_ ns: String) {
        namespace = ns
        loadRows()
    }

    // MARK: - 业务表（位图查询）

    func setBizMode(_ on: Bool) {
        bizMode = on
        selection = nil
        detail = ""
        if on {
            refreshBizStats()
            loadBiz()
        } else {
            loadRows()
        }
    }

    /// 按当前筛选器跑一次位图查询；sidecar 只回命中的 key + 值
    func loadBiz() {
        guard let sc = sidecar else { return }
        var eq: [String: Any] = [:]
        if !filterDept.isEmpty { eq["dept"] = filterDept }
        if !filterStatus.isEmpty { eq["status"] = filterStatus }
        var filter: [String: Any] = [:]
        if !eq.isEmpty { filter["eq"] = eq }
        if filterLevelMin > 0 { filter["gte"] = ["level": filterLevelMin] }
        if filterLevelMax < 8 { filter["lte"] = ["level": filterLevelMax] }

        busy = true
        work.async { [weak self] in
            guard let self else { return }
            let resp = sc.send(["op": "biz.query", "filter": filter, "limit": 500])
            guard let r = resp?["result"] as? [String: Any] else {
                let err = resp?["error"] as? String ?? "无响应"
                self.onMain {
                    self.busy = false
                    self.statusLine = "业务表查询失败：\(err)"
                }
                return
            }
            let matched = r["matched"] as? Int ?? 0
            let took = r["took_us"] as? Double ?? 0
            let arr = r["rows"] as? [[String: Any]] ?? []
            let rows: [Row] = arr.compactMap { item in
                guard let key = item["key"] as? String else { return nil }
                return Row(key: key, summary: Self.summarize(item["value"]), ts: 0)
            }
            self.onMain {
                self.rows = rows
                self.bizMatched = matched
                self.bizTookUs = took
                self.busy = false
                self.statusLine = String(
                    format: "业务表：命中 %d 条，位图查询 %.0f µs（显示前 %d 条）",
                    matched, took, rows.count
                )
            }
        }
    }

    func selectBiz(_ row: Row) {
        selection = row
        guard let sc = sidecar else { return }
        work.async { [weak self] in
            guard let self else { return }
            var text = ""
            if let resp = sc.send(["op": "biz.get", "key": row.key]),
               let r = resp["result"] as? [String: Any],
               let v = r["value"],
               let data = try? JSONSerialization.data(
                   withJSONObject: v,
                   options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
               ) {
                text = String(data: data, encoding: .utf8) ?? ""
            }
            self.onMain { self.detail = text.isEmpty ? "（行已不存在）" : text }
        }
    }

    func refreshBizStats() {
        guard let sc = sidecar else { return }
        work.async { [weak self] in
            guard let self, let r = sc.send(["op": "biz.info"])?["result"] as? [String: Any] else { return }
            let pages = r["pages"] as? [String: Any] ?? [:]
            let index = r["index"] as? [String: Any] ?? [:]
            let line = String(
                format: "页 %d · 行 %d · 重写 %d · 位图 %d · 占用 %.2f MB",
                pages["pages"] as? Int ?? 0,
                pages["rows"] as? Int ?? 0,
                pages["rewrites"] as? Int ?? 0,
                index["bitmaps"] as? Int ?? 0,
                Double(pages["bytes"] as? Int ?? 0) / 1_048_576
            )
            self.onMain { self.bizStatsLine = line }
        }
    }

    func clearBiz() {
        guard let sc = sidecar else { return }
        busy = true
        work.async { [weak self] in
            guard let self else { return }
            let r = sc.send(["op": "biz.clear"])?["result"] as? [String: Any] ?? [:]
            let rows = r["rows"] as? Int ?? 0
            self.onMain {
                self.busy = false
                self.statusLine = "已清空业务表：\(rows) 行，页目录重置"
                self.rows = []
                self.detail = ""
                self.selection = nil
                self.refreshBizStats()
                self.refreshInfo()
            }
        }
    }

    // MARK: - 工具：调外部命令（造数据 / 压测）

    func runTool(_ title: String, args: [String]) {
        guard !dbPath.isEmpty else { return }
        guard let rt = Sidecar.locateRuntime() else {
            log = "找不到 mstore 内核"
            return
        }
        let cli = rt.cli
        let root = (cli as NSString).deletingLastPathComponent
        busy = true
        statusLine = "\(title)…"
        let db = dbPath
        work.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rt.node)
            p.currentDirectoryURL = URL(fileURLWithPath: root)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do {
                try p.run()
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                self?.onMain {
                    self?.busy = false
                    self?.statusLine = "\(title) 完成（exit \(p.terminationStatus)）"
                    self?.log = text
                    self?.refreshInfo()
                }
                _ = db
            } catch {
                self?.onMain {
                    self?.busy = false
                    self?.statusLine = "\(title) 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func generateData() {
        // 演示库：业务行 + 抓包 + agent body 都有，界面三种视图都能看到东西
        runTool("造演示数据", args: ["bench/demo.ts", "--out", dbPath])
    }

    func runBench() {
        runTool("压测", args: ["bench/bench.ts", "--file", dbPath])
    }

    // MARK: - 辅助

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    static func summarize(_ v: Any?) -> String {
        guard let v else { return "—" }
        if let d = v as? [String: Any] {
            let keys = ["agent", "method", "host", "path", "status", "name", "dept", "bytes"]
            let parts = keys.compactMap { k -> String? in
                guard let x = d[k] else { return nil }
                return "\(k)=\(x)"
            }
            if !parts.isEmpty { return parts.joined(separator: "  ") }
            return "\(d.count) 个字段"
        }
        return "\(v)"
    }
}
