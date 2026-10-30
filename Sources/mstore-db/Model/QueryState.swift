import Foundation

/// 查询用的操作符。刻意只留 4 种：内核的 Filter 就这四个自由度
/// （枚举等值 / 枚举多值 / 数值上下界），UI 不发明内核做不到的东西。
enum QueryOp: String, CaseIterable, Identifiable, Sendable {
    case equals
    case anyOf
    case atLeast
    case atMost
    case between

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equals: "等于"
        case .anyOf: "属于其一"
        case .atLeast: "不小于"
        case .atMost: "不大于"
        case .between: "介于"
        }
    }

    var symbol: String {
        switch self {
        case .equals: "="
        case .anyOf: "∈"
        case .atLeast: "≥"
        case .atMost: "≤"
        case .between: "↔"
        }
    }

    var needsNumber: Bool {
        self == .atLeast || self == .atMost || self == .between
    }
}

/// 一个查询条件：字段 + 操作符 + 值
struct QueryCondition: Identifiable, Hashable, Sendable {
    let id: UUID
    var field: String
    var op: QueryOp
    var value: String
    /// `between` 的上界
    var upper: String

    init(id: UUID = UUID(), field: String, op: QueryOp = .equals, value: String = "", upper: String = "") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.upper = upper
    }

    var isValid: Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        if op.needsNumber, Double(v) == nil { return false }
        if op == .between {
            let u = upper.trimmingCharacters(in: .whitespaces)
            return !u.isEmpty && Double(u) != nil
        }
        return true
    }
}

/// 查询状态（可序列化为内核的 Filter）
struct QueryState: Sendable {
    var conditions: [QueryCondition] = []
    var limit: Int = 300

    /// 转成 `FilterPayload`。
    ///
    /// 同一字段被多个条件命中时**后者覆盖前者**——内核的 Filter 每个字段只有一个槽位。
    /// 这里不偷偷合并：`descriptor` 会显示最终生效的条件，界面上一眼能看出来，
    /// 比悄悄丢掉一个条件诚实。
    func payload() -> FilterPayload {
        var f = FilterPayload()
        for c in conditions where c.isValid {
            let v = c.value.trimmingCharacters(in: .whitespaces)
            switch c.op {
            case .equals:
                f.eq[c.field] = [v]
            case .anyOf:
                let list = v.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !list.isEmpty { f.eq[c.field] = list }
            case .atLeast:
                if let n = Double(v) { f.gte[c.field] = n }
            case .atMost:
                if let n = Double(v) { f.lte[c.field] = n }
            case .between:
                if let n = Double(v) { f.gte[c.field] = n }
                if let u = Double(c.upper.trimmingCharacters(in: .whitespaces)) { f.lte[c.field] = u }
            }
        }
        return f
    }

    var descriptor: String { payload().descriptor }

    var activeCount: Int { conditions.filter(\.isValid).count }

    /// 从命令行解析初始条件，形如 `dept=R&D;level>=5;status=active,leave`。
    ///
    /// 存在的理由不是炫技：没有它就没法在无人操作的情况下验证查询链路，
    /// 而「UI 能点」和「查询真的走位图」是两件事，后者必须能被脚本证明。
    static func parse(_ spec: String) -> [QueryCondition] {
        spec.split(separator: ";").compactMap { piece -> QueryCondition? in
            let text = piece.trimmingCharacters(in: .whitespaces)
            if let r = text.range(of: ">=") {
                return QueryCondition(
                    field: String(text[text.startIndex..<r.lowerBound]),
                    op: .atLeast,
                    value: String(text[r.upperBound...])
                )
            }
            if let r = text.range(of: "<=") {
                return QueryCondition(
                    field: String(text[text.startIndex..<r.lowerBound]),
                    op: .atMost,
                    value: String(text[r.upperBound...])
                )
            }
            guard let i = text.firstIndex(of: "=") else { return nil }
            let field = String(text[text.startIndex..<i])
            let raw = String(text[text.index(after: i)...])
            if raw.contains(",") {
                return QueryCondition(field: field, op: .anyOf, value: raw)
            }
            return QueryCondition(field: field, op: .equals, value: raw)
        }
    }
}
