import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.connected {
                HSplitView {
                    infoPane.frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
                    listPane.frame(minWidth: 360)
                    detailPane.frame(minWidth: 320)
                }
            } else {
                emptyState
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1040, minHeight: 640)
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("输出").font(.headline)
                    Spacer()
                    Button("关闭") { showLog = false }
                }
                ScrollView {
                    Text(model.log.isEmpty ? "（暂无输出）" : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(width: 720, height: 460)
        }
    }

    // MARK: - 顶部工具条

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("打开库…") { openPanel() }
                Button("新建库…") { savePanel() }
                Divider().frame(height: 18)
                Picker("", selection: Binding(
                    get: { model.bizMode },
                    set: { model.setBizMode($0) }
                )) {
                    Text("记录").tag(false)
                    Text("业务表").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                if model.bizMode {
                    Picker("", selection: Binding(
                        get: { model.filterDept },
                        set: { model.filterDept = $0; model.loadBiz() }
                    )) {
                        Text("全部部门").tag("")
                        ForEach(AppModel.depts, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 130)
                    Picker("", selection: Binding(
                        get: { model.filterStatus },
                        set: { model.filterStatus = $0; model.loadBiz() }
                    )) {
                        Text("全部状态").tag("")
                        ForEach(AppModel.statuses, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 120)
                    Stepper(
                        "level ≥ \(model.filterLevelMin)",
                        value: Binding(
                            get: { model.filterLevelMin },
                            set: { model.filterLevelMin = min($0, model.filterLevelMax); model.loadBiz() }
                        ),
                        in: 0...8
                    )
                    .frame(width: 130)
                    Stepper(
                        "≤ \(model.filterLevelMax)",
                        value: Binding(
                            get: { model.filterLevelMax },
                            set: { model.filterLevelMax = max($0, model.filterLevelMin); model.loadBiz() }
                        ),
                        in: 0...8
                    )
                    .frame(width: 100)
                } else {
                    Picker("", selection: Binding(
                        get: { model.namespace },
                        set: { model.switchNamespace($0) }
                    )) {
                        ForEach(AppModel.namespaces, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                Button("刷新") {
                    if model.bizMode {
                        model.loadBiz()
                        model.refreshBizStats()
                    } else {
                        model.loadRows()
                    }
                    model.refreshInfo()
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 10) {
                Button("造演示数据") { model.generateData() }.disabled(!model.connected || model.busy)
                Button("跑压测") { model.runBench() }.disabled(!model.connected || model.busy)
                Button("自检") { model.check() }.disabled(!model.connected || model.busy)
                if model.bizMode {
                    Button("清空业务表") { model.clearBiz() }.disabled(!model.connected || model.busy)
                } else {
                    Button("清空本 ns") { model.clearNamespace() }.disabled(!model.connected || model.busy)
                }
                if !model.log.isEmpty {
                    Button("查看输出") { showLog = true }
                }
                Spacer()
                if model.bizMode {
                    Text(model.bizStatsLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - 左：库信息

    private var infoPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("库信息").font(.headline).padding(.horizontal, 14).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.info.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pair.0).font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                            Text(pair.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - 中：记录列表

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.bizMode ? "业务表" : model.namespace).font(.headline)
                Text(model.bizMode ? "\(model.bizMatched) 命中 · \(model.rows.count) 显示" : "\(model.rows.count) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12)
            List {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.key)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            Spacer()
                            Text(timeText(row.ts)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(row.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.bizMode { model.selectBiz(row) } else { model.select(row) }
                    }
                    .listRowBackground(
                        model.selection?.key == row.key
                            ? Color.accentColor.opacity(0.16) : Color.clear
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 右：详情

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selection?.key ?? "未选中").font(.headline)
                Spacer()
                if !model.bizMode {
                    Button("读 body 前 4KB") { model.peekBody() }
                        .disabled(model.selection == nil)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)
            ScrollView {
                Text(model.detail.isEmpty ? "点左侧任意一条查看内容。\n\nbody 是按 offset 直接读的，sidecar 不解析它。" : model.detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("mstore-db").font(.system(size: 22, weight: .medium))
            Text("选一个 store.db，或新建一个。数据由 sidecar 提供，界面只负责展示。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("打开库…") { openPanel() }
                Button("新建库…") { savePanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(model.dbPath).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func timeText(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ts) / 1000)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 面板

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "选择 store.db（或任意 mstore 文件）"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(path: url.path)
        }
    }

    private func savePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "app.db"
        panel.message = "新建一个空库"
        if panel.runModal() == .OK, let url = panel.url {
            let p = Process()
            guard let rt = Sidecar.locateRuntime() else {
                model.log = "找不到 mstore 内核"
                return
            }
            p.executableURL = URL(fileURLWithPath: rt.node)
            p.arguments = [rt.cli, "init", url.path]
            try? p.run()
            p.waitUntilExit()
            model.open(path: url.path)
        }
    }
}
