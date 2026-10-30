import Foundation

/// 面向业务的 sidecar 客户端。
///
/// 是一个 `actor`：所有请求天然串行，正好对上内核「单写者」的模型；
/// 阻塞的管道读写挂在一条专用队列上，不占 cooperative pool 的线程
/// （在 cooperative pool 上做 fsync 级别的阻塞会把整个并发系统拖住）。
///
/// 边界纪律：`[String: Any]` 只在 actor 内部存在，出去的一律是 `Payloads.swift`
/// 里的 Sendable 值类型。
actor StoreClient {
    private var sidecar: Sidecar?
    private let queue = DispatchQueue(label: "mstore-db.sidecar", qos: .userInitiated)

    var isOpen: Bool { sidecar != nil }

    // MARK: - 生命周期

    func open(path: String) async throws -> Handshake {
        if let old = sidecar {
            sidecar = nil
            let drop = old
            try? await onQueue { drop.stop() }
        }
        let sc = Sidecar()
        let hs: Handshake = try await onQueue {
            try sc.start(dbPath: path)
            let h = sc.hello
            let stats = h["stats"] as? [String: Any] ?? [:]
            let snap = stats["snapshot"] as? [String: Any] ?? [:]
            return Handshake(
                pid: h["pid"] as? Int ?? 0,
                crc: h["crc"] as? String ?? "?",
                snapshotPath: snap["path"] as? String ?? "?",
                snapshotNote: snap["note"] as? String ?? "",
                openMs: snap["openMs"] as? Double ?? 0
            )
        }
        sidecar = sc
        return hs
    }

    func close() async {
        guard let sc = sidecar else { return }
        sidecar = nil
        try? await onQueue { sc.stop() }
    }

    // MARK: - 读

    func summary() async -> StoreSummary? {
        guard let r = (await call(["op": "info"]))?["result"] as? [String: Any] else { return nil }
        let segs = r["segs"] as? [String: Any] ?? [:]
        let records = r["records"] as? [String: Any] ?? [:]
        let committer = r["committer"] as? [String: Any] ?? [:]
        let snap = r["snapshot"] as? [String: Any] ?? [:]
        var rec: [String: Int] = [:]
        for (k, v) in records { rec[k] = v as? Int ?? 0 }
        return StoreSummary(
            file: r["file"] as? String ?? "",
            bytesLogical: r["bytesLogical"] as? Int ?? 0,
            shellSegs: segs["shell"] as? Int ?? 0,
            bodySegs: segs["body"] as? Int ?? 0,
            snapshotSegs: segs["snapshot"] as? Int ?? 0,
            deadSegs: r["deadSegs"] as? Int ?? 0,
            pendingReclaim: r["pendingReclaim"] as? Int ?? 0,
            records: rec,
            crcImpl: r["crcImpl"] as? String ?? "?",
            commits: committer["commits"] as? Int ?? 0,
            avgBatch: committer["avgBatch"] as? Double ?? 0,
            fsyncEwma: committer["fsyncMsEwma"] as? Double ?? 0,
            snapshotPath: snap["path"] as? String ?? "?",
            snapshotNote: snap["note"] as? String ?? "",
            openMs: snap["openMs"] as? Double ?? 0,
            snapshotBytes: snap["bytes"] as? Int ?? 0,
            snapshotRows: snap["rows"] as? Int ?? 0,
            snapshotCurrent: snap["current"] as? Bool ?? false
        )
    }

    func list(ns: Namespace, limit: Int) async -> [Record] {
        let resp = await call(["op": "list", "ns": ns.rawValue, "limit": limit])
        let arr = resp?["result"] as? [[String: Any]] ?? []
        return arr.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            return Record(
                key: key,
                summary: Self.summarize(item["value"]),
                ts: item["ts"] as? Int ?? 0
            )
        }
    }

    /// 一条记录的完整 JSON（body 只给定位信息，不读内容）
    func record(ns: Namespace, key: String) async -> String {
        guard let r = (await call(["op": "get", "ns": ns.rawValue, "key": key]))?["result"] as? [String: Any]
        else { return "（记录已不存在）" }
        var text = Self.pretty(r["value"]) ?? "null"
        if let b = r["body"] as? [String: Any] {
            let len = b["l"] as? Int ?? 0
            let off = b["o"] as? Int ?? 0
            let seg = b["s"] as? Int ?? 0
            text += "\n\n// body \(Self.bytes(len))  @off=\(off)  seg=\(seg)\n// 按 offset 直读，不 parse 全文"
        }
        return text
    }

    /// body 前 4KB 原样读出
    func bodyPeek(ns: Namespace, key: String) async -> String {
        guard let r = (await call(["op": "body", "ns": ns.rawValue, "key": key]))?["result"] as? [String: Any],
              let b64 = r["base64"] as? String,
              let data = Data(base64Encoded: b64)
        else { return "（这条记录没有 body）" }
        let head = data.prefix(4096)
        let text = String(data: head, encoding: .utf8) ?? "<二进制 \(data.count) 字节>"
        return "// body 共 \(Self.bytes(data.count))，以下是前 \(head.count) 字节（未 parse）\n\n" + text
    }

    // MARK: - 业务表

    func tableSummary() async -> TableSummary? {
        guard let r = (await call(["op": "biz.info"]))?["result"] as? [String: Any] else { return nil }
        let pages = r["pages"] as? [String: Any] ?? [:]
        let index = r["index"] as? [String: Any] ?? [:]
        var enumValues: [String: [String]] = [:]
        if let raw = index["enumValues"] as? [String: Any] {
            for (k, v) in raw { enumValues[k] = (v as? [String]) ?? [] }
        }
        return TableSummary(
            pages: pages["pages"] as? Int ?? 0,
            rows: pages["rows"] as? Int ?? 0,
            rewrites: pages["rewrites"] as? Int ?? 0,
            pageBytes: pages["bytes"] as? Int ?? 0,
            bitmaps: index["bitmaps"] as? Int ?? 0,
            enumValues: enumValues,
            numFields: index["nums"] as? [String] ?? []
        )
    }

    func query(_ filter: FilterPayload, limit: Int) async -> QueryOutcome? {
        var f: [String: Any] = [:]
        if !filter.eq.isEmpty { f["eq"] = filter.eq }
        if !filter.gte.isEmpty { f["gte"] = filter.gte }
        if !filter.lte.isEmpty { f["lte"] = filter.lte }
        let resp = await call(["op": "biz.query", "filter": f, "limit": limit])
        if let err = resp?["error"] as? String {
            return QueryOutcome(matched: -1, tookUs: 0, rows: [TableRow(key: "错误：\(err)", rowid: -1, summary: "", json: "")])
        }
        guard let r = resp?["result"] as? [String: Any] else { return nil }
        let arr = r["rows"] as? [[String: Any]] ?? []
        let rows: [TableRow] = arr.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            return TableRow(
                key: key,
                rowid: item["rowid"] as? Int ?? -1,
                summary: Self.summarize(item["value"]),
                json: Self.pretty(item["value"]) ?? "null"
            )
        }
        return QueryOutcome(
            matched: r["matched"] as? Int ?? 0,
            tookUs: r["took_us"] as? Double ?? 0,
            rows: rows
        )
    }

    func tableRow(key: String) async -> String {
        guard let r = (await call(["op": "biz.get", "key": key]))?["result"] as? [String: Any]
        else { return "（行已不存在）" }
        return Self.pretty(r["value"]) ?? "（行已不存在）"
    }

    // MARK: - 维护

    func check() async -> String {
        guard let r = (await call(["op": "check"]))?["result"] as? [String: Any] else { return "自检无响应" }
        let ok = r["ok"] as? Bool ?? false
        let issues = r["issues"] as? [[String: Any]] ?? []
        if ok && issues.isEmpty {
            return "自检通过：段 \(r["segs"] as? Int ?? 0)（shell \(r["shellSegs"] as? Int ?? 0) / body \(r["bodySegs"] as? Int ?? 0)），记录 \(r["records"] as? Int ?? 0)"
        }
        let head = ok ? "自检通过，但有 \(issues.count) 条告警" : "自检失败：\(issues.count) 个问题"
        let body = issues.prefix(20).map { "· [\($0["level"] ?? "?")] \($0["where"] ?? "") \($0["detail"] ?? "")" }
        return ([head] + body).joined(separator: "\n")
    }

    func clear(ns: Namespace) async -> String {
        guard let r = (await call(["op": "clear", "ns": ns.rawValue]))?["result"] as? [String: Any]
        else { return "清空失败" }
        let dead = r["deadSegs"] as? Int ?? 0
        let freed = Double(r["freedBytes"] as? Int ?? 0) / 1_048_576
        return "清空 \(ns.rawValue)：\(dead) 段，归还 \(String(format: "%.2f", freed)) MB"
    }

    func clearTable() async -> String {
        guard let r = (await call(["op": "biz.clear"]))?["result"] as? [String: Any] else { return "清空失败" }
        return "已清空业务表：\(r["rows"] as? Int ?? 0) 行，页目录重置"
    }

    // MARK: - 内部

    private func call(_ req: [String: Any]) async -> [String: Any]? {
        guard let sc = sidecar, let data = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        let raw: Data? = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: sc.exchange(data)) }
        }
        guard let raw else { return nil }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - 格式化

    static func pretty(_ v: Any?) -> String? {
        guard let v else { return nil }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: opts) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func summarize(_ v: Any?) -> String {
        guard let v else { return "—" }
        guard let d = v as? [String: Any] else { return "\(v)" }
        let order = ["agent", "name", "method", "url", "path", "status", "dept", "level", "kind", "bytes", "ms"]
        var parts: [String] = []
        for k in order {
            guard let x = d[k] else { continue }
            parts.append("\(k)=\(x)")
            if parts.count >= 4 { break }
        }
        if !parts.isEmpty { return parts.joined(separator: "  ") }
        return "\(d.count) 个字段"
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1_048_576 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1_048_576)
    }
}
