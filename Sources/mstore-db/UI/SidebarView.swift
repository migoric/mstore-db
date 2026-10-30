import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(Namespace.allCases) { ns in
                    row(
                        title: ns.title,
                        subtitle: ns.subtitle,
                        symbol: ns.symbol,
                        count: model.summary?.records[ns.rawValue] ?? 0,
                        tag: .records(ns)
                    )
                }
            } header: {
                SectionLabel(text: "命名空间")
            }

            Section {
                row(
                    title: "业务表",
                    subtitle: "页表 + 位图索引",
                    symbol: "tablecells",
                    count: model.table?.rows ?? 0,
                    tag: .table,
                    disabled: !model.canUseTable
                )
            } header: {
                SectionLabel(text: "查询")
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle("mstore")
    }

    private var selection: Binding<AppModel.Mode?> {
        Binding(
            get: { model.phase == .ready ? model.mode : nil },
            set: { if let v = $0 { withAnimation(Theme.spring) { model.mode = v } } }
        )
    }

    private func row(
        title: String,
        subtitle: String,
        symbol: String,
        count: Int,
        tag: AppModel.Mode,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if count > 0 {
                CountBadge(value: count)
            }
        }
        .padding(.vertical, 2)
        .opacity(disabled ? 0.45 : 1)
        .tag(tag)
        .disabled(disabled)
    }

    // MARK: - 底部状态

    private var footer: some View {
        VStack(spacing: 8) {
            if let s = model.summary {
                GlassPanel(padding: 11) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            StatusDot(ready: model.phase == .ready)
                            Text(s.fileName)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(s.sizeText)
                                .font(Theme.mono(10))
                                .foregroundStyle(.tertiary)
                        }

                        Divider().opacity(0.4)

                        // 冷启动走的路：这一行是快照优化的唯一可见证据
                        HStack(spacing: 5) {
                            Image(systemName: s.usedSnapshot ? "bolt.horizontal.fill" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                                .foregroundStyle(s.usedSnapshot ? .green : .orange)
                            Text(s.usedSnapshot ? "索引快照" : "逐页重放")
                                .font(Theme.label(10, .medium))
                            Text(String(format: "%.1f ms", s.openMs))
                                .font(Theme.mono(10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if s.snapshotBytes > 0 {
                                Text(StoreClient.bytes(s.snapshotBytes))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(.quaternary)
                            }
                        }

                        if !s.snapshotNote.isEmpty {
                            Text(s.snapshotNote)
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                                .lineLimit(2)
                        }

                        HStack(spacing: 10) {
                            miniStat("shell", "\(s.shellSegs)")
                            miniStat("body", "\(s.bodySegs)")
                            miniStat("死段", "\(s.deadSegs)")
                            Spacer(minLength: 0)
                            Text(s.crcImpl)
                                .font(Theme.mono(9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .transition(.blurReplace)
            }

            HStack(spacing: 6) {
                IconButton(symbol: "folder", help: "打开另一个库") { openPanel() }
                IconButton(symbol: "arrow.clockwise", help: "重新读取") { model.reload() }
                IconButton(symbol: "stethoscope", help: "自检：段头 / CRC / body 越界") { model.check() }

                Spacer(minLength: 0)

                if model.busy {
                    ProgressView().controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(Theme.spring, value: model.summary?.bytesLogical)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        panel.message = "选择 store.db"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(path: url.path)
        }
    }

    private func miniStat(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(Theme.mono(9, .medium)).foregroundStyle(.secondary)
        }
    }
}
