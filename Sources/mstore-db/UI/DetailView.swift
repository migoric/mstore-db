import SwiftUI
import AppKit

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if model.detail.isEmpty {
                EmptyHint(
                    symbol: "curlybraces",
                    title: "没有选中的记录",
                    message: "body 是按 offset 直接读的，sidecar 不 parse 它——所以再大的 JSON 也不会拖慢列表。"
                )
            } else {
                ScrollView {
                    Text(JSONHighlight.styled(model.detail))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.pad)
                        .padding(.vertical, 12)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .transition(.blurReplace)
            }
        }
        .animation(Theme.quick, value: model.detail)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedKey ?? "详情")
                    .font(Theme.mono(12, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.detail.isEmpty {
                    Text("\(model.detail.utf8.count) 字节")
                        .font(Theme.mono(9))
                        .foregroundStyle(.quaternary)
                }
            }
            Spacer(minLength: 6)

            if case .records = model.mode, model.selectedKey != nil {
                IconButton(symbol: "doc.text.magnifyingglass", help: "读 body 前 4KB（演示 offset 直读）") {
                    model.peekBody()
                }
            }

            IconButton(symbol: "doc.on.doc", help: "复制全部", disabled: model.detail.isEmpty) {
                copy()
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(model.detail, forType: .string)
    }
}

/// 输出面板（自检 / 造数据 / 压测）
struct LogSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("输出").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("复制") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(model.log, forType: .string)
                }
                .buttonStyle(.glass)
                Button("关闭") { model.showLog = false }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(model.log.isEmpty ? "（暂无输出）" : model.log)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .padding(16)
        .frame(width: 760, height: 480)
    }
}
