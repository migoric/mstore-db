import Foundation

/// 跨 actor 边界传的值类型。
///
/// 规则：**只有这里定义的值类型能过边界**。sidecar 协议本身是 `[String: Any]`，
/// 它不 Sendable，所以 JSON 的组装和解码都在 `StoreClient` 的 actor 内部完成，
/// 出去的一律是 struct + String + 基本数值。
enum Namespace: String, CaseIterable, Sendable, Identifiable {
    case capture, biz, agent, mock
    var id: String { rawValue }

    var title: String { rawValue }
    var subtitle: String {
        switch self {
        case .capture: "抓包记录"
        case .biz: "业务数据"
        case .agent: "agent 结果"
        case .mock: "mock 接口"
        }
    }
    var symbol: String {
        switch self {
        case .capture: "antenna.radiowaves.left.and.right"
        case .biz: "tablecells"
        case .agent: "sparkles"
        case .mock: "square.stack.3d.up"
        }
    }
}

/// 一条 KV 记录（不是业务表行）
struct Record: Identifiable, Hashable, Sendable {
    let key: String
    let summary: String
    let ts: Int
    var id: String { key }

    var tsText: String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ts) / 1000)
        return d.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}

/// 一条业务表行
struct TableRow: Identifiable, Hashable, Sendable {
    let key: String
    let rowid: Int
    let summary: String
    /// 值的 pretty JSON，UI 直接高亮显示，不再二次解析
    let json: String
    var id: String { key }
}

/// 查询条件（跨边界用的扁平形式，和内核的 Filter 一一对应）
struct FilterPayload: Sendable, Equatable {
    var eq: [String: [String]] = [:]
    var gte: [String: Double] = [:]
    var lte: [String: Double] = [:]

    var isEmpty: Bool { eq.isEmpty && gte.isEmpty && lte.isEmpty }

    /// 给界面显示的一句话描述
    var descriptor: String {
        var parts: [String] = []
        for (k, v) in eq.sorted(by: { $0.key < $1.key }) {
            parts.append(v.count == 1 ? "\(k) = \(v[0])" : "\(k) ∈ {\(v.joined(separator: ", "))}")
        }
        for (k, v) in gte.sorted(by: { $0.key < $1.key }) { parts.append("\(k) ≥ \(fmt(v))") }
        for (k, v) in lte.sorted(by: { $0.key < $1.key }) { parts.append("\(k) ≤ \(fmt(v))") }
        return parts.isEmpty ? "全部行" : parts.joined(separator: "  ·  ")
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

/// 一次查询的结果
struct QueryOutcome: Sendable {
    var matched: Int
    var tookUs: Double
    var rows: [TableRow]
}

/// 库的统计信息（侧栏展示）
struct StoreSummary: Sendable {
    var file: String
    var bytesLogical: Int
    var shellSegs: Int
    var bodySegs: Int
    var snapshotSegs: Int
    var deadSegs: Int
    var pendingReclaim: Int
    var records: [String: Int]
    var crcImpl: String
    var commits: Int
    var avgBatch: Double
    var fsyncEwma: Double

    // 冷启动走的哪条路：snapshot 是「索引快照命中」，replay 是「逐页重放」
    var snapshotPath: String
    var snapshotNote: String
    var openMs: Double
    var snapshotBytes: Int
    var snapshotRows: Int
    var snapshotCurrent: Bool

    var fileName: String { (file as NSString).lastPathComponent }
    var usedSnapshot: Bool { snapshotPath == "snapshot" }
    var sizeText: String { String(format: "%.2f MB", Double(bytesLogical) / 1_048_576) }
}

/// 业务表（页表 + 位图索引）的状态
struct TableSummary: Sendable {
    var pages: Int
    var rows: Int
    var rewrites: Int
    var pageBytes: Int
    var bitmaps: Int
    /// 枚举字段 → 该字段出现过的值（查询构建器的候选项）
    var enumValues: [String: [String]]
    var numFields: [String]

    var bytesText: String { String(format: "%.2f MB", Double(pageBytes) / 1_048_576) }
}

/// 打开库时的握手信息
struct Handshake: Sendable {
    var pid: Int
    var crc: String
    var snapshotPath: String
    var snapshotNote: String
    var openMs: Double
}
