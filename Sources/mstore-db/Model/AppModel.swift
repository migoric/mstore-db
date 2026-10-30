import Foundation
import AppKit

/// 界面状态。
///
/// 只做三件事：持有 `StoreClient`、把结果搬到 `@Published`、把用户动作翻译成一次 client 调用。
/// 所有耗时逻辑都在 client 的 actor 里，这里**不允许**出现同步阻塞调用——
/// 主线程上一旦有一次 fsync 级别的等待，Liquid Glass 的动画就会掉帧。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, connecting, ready, failed }
    enum Mode: Hashable, Sendable {
        case records(Namespace)
        case table
    }

    // 连接
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var handshake: Handshake?
    @Published private(set) var dbPath = ""

    // 数据
    @Published private(set) var summary: StoreSummary?
    @Published private(set) var table: TableSummary?
    @Published private(set) var records: [Record] = []
    @Published private(set) var tableRows: [TableRow] = []
    @Published private(set) var outcome: QueryOutcome?
    @Published var selectedKey: String?
    @Published private(set) var detail = ""

    // 查询
    @Published var query = QueryState()

    // 状态栏
    @Published private(set) var status = "未连接"
    @Published private(set) var busy = false
    @Published private(set) var lastOpenNote = ""
    @Published var log = ""
    @Published var showLog = false

    @Published var mode: Mode = .records(.capture) {
        didSet { if mode != oldValue { reload() } }
    }

    /// 命令行 `--table` 时，连上之后直接进业务表视图
    var pendingTableMode = false
    /// 命令行 `--filter` 的初始条件，连上之后应用
    var pendingFilter: String = ""

    let client = StoreClient()

    var canUseTable: Bool { (table?.rows ?? 0) > 0 || (table?.pages ?? 0) > 0 }

    // MARK: - 连接

    func open(path: String) {
        dbPath = path
        phase = .connecting
        status = "正在启动 sidecar…"
        Task { await doOpen(path: path) }
    }

    private func doOpen(path: String) async {
        do {
            let hs = try await client.open(path: path)
            handshake = hs
            phase = .ready
            lastOpenNote = hs.snapshotNote
            status = hs.snapshotPath == "snapshot"
                ? "已连接 · 索引快照命中 \(fmt(hs.openMs)) ms"
                : "已连接 · 逐页重放 \(fmt(hs.openMs)) ms"
            if !pendingFilter.isEmpty {
                query.conditions = QueryState.parse(pendingFilter)
                pendingFilter = ""
            }
            if pendingTableMode {
                pendingTableMode = false
                mode = .table
            } else {
                // reload() 是同步的（内部自己开 Task），在这里 await 它会被判定为
                // 「no 'async' operations occur within 'await' expression」——CI 的零 warning
                // 门禁会红。这里要的是「打开完成时列表已经就绪」，所以直接等 doReload()。
                await doReload()
            }
        } catch {
            phase = .failed
            status = "连接失败：\(error.localizedDescription)"
        }
    }

    func disconnect() {
        Task { await client.close() }
        phase = .idle
        handshake = nil
        summary = nil
        table = nil
        records = []
        tableRows = []
        outcome = nil
        detail = ""
        selectedKey = nil
        status = "已断开"
    }

    /// 关窗口时调用：先让 sidecar 走 quit，把 meta 与快照落盘
    func shutdown() {
        let c = client
        Task.detached { await c.close() }
    }

    // MARK: - 读

    func reload() {
        Task { await doReload() }
    }

    private func doReload() async {
        guard phase == .ready else { return }
        busy = true
        defer { busy = false }
        async let s = client.summary()
        async let t = client.tableSummary()
        let (newSummary, newTable) = await (s, t)
        if let newSummary { summary = newSummary }
        if let newTable { table = newTable }

        switch mode {
        case .records(let ns):
            records = await client.list(ns: ns, limit: 500)
            status = "\(ns.rawValue)：\(records.count) 条"
            if selectedKey == nil || !records.contains(where: { $0.key == selectedKey }) {
                selectedKey = records.first?.key
            }
        case .table:
            await doQuery()
        }
        if selectedKey != nil { await loadDetail() }
    }

    /// 选中一条之后把详情拉回来。列表用 `List(selection:)` 绑 `selectedKey`，
    /// 真正的加载统一走这里，避免「点一下加载一次、键盘上下移动又加载一次」的两套逻辑。
    func loadDetail() async {
        guard let key = selectedKey else {
            detail = ""
            return
        }
        switch mode {
        case .records(let ns):
            detail = await client.record(ns: ns, key: key)
        case .table:
            // `??` 的右边是 autoclosure，放不进去 async 调用，只能老老实实分支
            if let hit = tableRows.first(where: { $0.key == key }) {
                detail = hit.json
            } else {
                detail = await client.tableRow(key: key)
            }
        }
    }

    func select(_ record: Record) {
        selectedKey = record.key
    }

    func selectRow(_ row: TableRow) {
        selectedKey = row.key
        detail = row.json
    }

    func peekBody() {
        guard case .records(let ns) = mode, let key = selectedKey else { return }
        Task { detail = await client.bodyPeek(ns: ns, key: key) }
    }

    // MARK: - 查询

    func runQuery() {
        Task { await doQuery() }
    }

    private func doQuery() async {
        guard phase == .ready else { return }
        busy = true
        defer { busy = false }
        let payload = query.payload()
        guard let out = await client.query(payload, limit: query.limit) else {
            status = "查询无响应"
            return
        }
        outcome = out
        tableRows = out.rows
        status = out.matched < 0
            ? (out.rows.first?.key ?? "查询失败")
            : "命中 \(out.matched) 行 · 位图 \(fmt(out.tookUs, digits: 1)) µs · 显示 \(out.rows.count) 行"
        // 查询结果换了之后：选中的行还在就保留，不在就落到第一行——
        // 让右边永远有东西可看，而不是每次改条件都要再点一下
        if let key = selectedKey, out.rows.contains(where: { $0.key == key }) {
            await loadDetail()
        } else {
            selectedKey = out.rows.first?.key
            await loadDetail()
        }
    }

    private var queryTask: Task<Void, Never>?
    /// 改一个条件就打一次位图查询是浪费：等 120ms 没有新输入再打
    func scheduleQuery() {
        queryTask?.cancel()
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await doQuery()
        }
    }

    func addCondition() {
        let field = table?.enumValues.keys.sorted().first
            ?? table?.numFields.first
            ?? "dept"
        let op: QueryOp = (table?.numFields.contains(field) ?? false) ? .atLeast : .equals
        query.conditions.append(QueryCondition(field: field, op: op, value: ""))
    }

    func removeCondition(_ id: UUID) {
        query.conditions.removeAll { $0.id == id }
        scheduleQuery()
    }

    func clearConditions() {
        query.conditions = []
        scheduleQuery()
    }

    /// 换字段时把操作符与值一起重置：枚举字段给了个「≥ 5」是没有意义的组合
    func changeField(_ id: UUID, to field: String) {
        guard let i = query.conditions.firstIndex(where: { $0.id == id }) else { return }
        let isNum = table?.numFields.contains(field) ?? false
        query.conditions[i].field = field
        query.conditions[i].op = isNum ? .atLeast : .equals
        query.conditions[i].value = ""
        query.conditions[i].upper = ""
        scheduleQuery()
    }

    // MARK: - 维护

    func check() {
        Task {
            busy = true
            log = await client.check()
            busy = false
            showLog = true
            await refreshSummary()
        }
    }

    func clearCurrentNamespace() {
        guard case .records(let ns) = mode else { return }
        Task {
            busy = true
            status = await client.clear(ns: ns)
            records = []
            selectedKey = nil
            detail = ""
            busy = false
            await refreshSummary()
        }
    }

    func clearTable() {
        Task {
            busy = true
            status = await client.clearTable()
            tableRows = []
            outcome = nil
            selectedKey = nil
            detail = ""
            busy = false
            await doReload()
        }
    }

    private func refreshSummary() async {
        async let s = client.summary()
        async let t = client.tableSummary()
        let (a, b) = await (s, t)
        if let a { summary = a }
        if let b { table = b }
    }

    // MARK: - 外部命令（造数据 / 压测）

    func generateDemo() {
        runTool("造演示数据", args: ["bench/demo.ts", "--out", dbPath])
    }

    func runBench() {
        runTool("压测", args: ["bench/bench.ts", "--file", dbPath])
    }

    /// 跑一个外部脚本（造数据 / 压测）。
    ///
    /// 不在这里直接 `Task.detached`：detached 里捕获 `self`（@MainActor）会被 Swift 6 判成
    /// 数据竞争。改成「把活交给一个 nonisolated 的静态函数，回来时再回主线程」，
    /// 数据流一眼能看完：进 → (status, text) → 出。
    private func runTool(_ title: String, args: [String]) {
        guard !dbPath.isEmpty else { return }
        guard let rt = Sidecar.locateRuntime() else {
            log = "找不到 mstore 内核"
            showLog = true
            return
        }
        let root = (rt.cli as NSString).deletingLastPathComponent
        busy = true
        status = "\(title)…"
        Task {
            let (code, text) = await Self.runProcess(node: rt.node, args: args, cwd: root)
            self.busy = false
            self.status = "\(title) 完成（exit \(code)）"
            self.log = text
            self.showLog = true
            self.reload()
        }
    }

    private nonisolated static func runProcess(node: String, args: [String], cwd: String) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: node)
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    cont.resume(returning: (-1, "启动失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - 辅助

    private func fmt(_ ms: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", ms)
    }
}
