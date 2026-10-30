import SwiftUI

/// 中栏：记录列表（KV 命名空间）与业务表结果共用一套骨架，
/// 差别只在「列是什么」和「上面挂不挂查询条」。
struct RecordListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .table = model.mode {
                QueryBar(model: model)
                    .padding(.horizontal, Theme.pad)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider().opacity(0.5)
            // `.id(mode)` 让换命名空间时真的重建列表：滚动位置回到顶部，
            // 切换动画也才有了可观察的「换了一批东西」，否则 SwiftUI 只会原地改内容。
            content
                .id(model.mode)
        }
        .animation(Theme.spring, value: model.mode)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.interpolate)

            Text(subtitle)
                .font(Theme.label(11))
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())

            Spacer(minLength: 6)

            if case .table = model.mode, let out = model.outcome, out.matched >= 0 {
                LatencyBadge(micros: out.tookUs)
            }

            IconButton(
                symbol: "wand.and.stars",
                help: "造演示数据：3000 行业务 + 2000 条抓包 + 20 个 agent body",
                disabled: model.phase != .ready || model.busy
            ) { model.generateDemo() }

            MenuIcon(symbol: "ellipsis.circle", help: "更多") {
                Button("自检（段头 / CRC / body 越界）") { model.check() }
                Divider()
                Button("清空当前命名空间") { model.clearCurrentNamespace() }
                Button("清空业务表") { model.clearTable() }
                Divider()
                Button("跑压测") { model.runBench() }
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var title: String {
        switch model.mode {
        case .records(let ns): ns.title
        case .table: "业务表"
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .records:
            return "\(model.records.count) 条"
        case .table:
            guard let s = model.table else { return "—" }
            let matched = model.outcome?.matched ?? 0
            return "命中 \(matched) / \(s.rows) 行 · 位图 \(s.bitmaps)"
        }
    }

    // MARK: - 列表

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .records:
            if model.records.isEmpty {
                EmptyHint(
                    symbol: "tray",
                    title: "这个命名空间是空的",
                    message: model.phase == .ready ? "用侧栏的「造演示数据」写一些进来，或换一个命名空间。" : "先打开一个库。"
                )
            } else {
                List(selection: $model.selectedKey) {
                    ForEach(model.records) { record in
                        recordRow(record).tag(record.key)
                    }
                }
                .listStyle(.inset)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .transition(.blurReplace)
            }

        case .table:
            if model.tableRows.isEmpty {
                EmptyHint(
                    symbol: model.query.activeCount > 0 ? "line.3.horizontal.decrease.circle" : "tablecells",
                    title: model.query.activeCount > 0 ? "没有命中的行" : "业务表还是空的",
                    message: model.query.activeCount > 0
                        ? "当前条件：\(model.query.descriptor)\n去掉一两个条件试试。"
                        : "业务数据走 CoW 页表 + 位图索引，和上面的 KV 记录是两套读法。"
                )
            } else {
                List(selection: $model.selectedKey) {
                    ForEach(model.tableRows) { row in
                        tableRow(row).tag(row.key)
                    }
                }
                .listStyle(.inset)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .transition(.blurReplace)
            }
        }
    }

    private func recordRow(_ record: Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.key)
                    .font(Theme.mono(11.5, .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(record.tsText)
                    .font(Theme.mono(9))
                    .foregroundStyle(.quaternary)
            }
            Text(record.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func tableRow(_ row: TableRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.key)
                    .font(Theme.mono(11.5, .medium))
                    .lineLimit(1)
                Text("#\(row.rowid)")
                    .font(Theme.mono(9))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 6)
            }
            Text(row.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
