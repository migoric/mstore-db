import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: Theme.sidebarIdeal, max: 330)
        } content: {
            RecordListView(model: model)
                // 内容区用 regularMaterial 而不是「透明」：窗口本身是透明的（玻璃要采样），
                // 但列表背后的桌面文字会直接穿过来，可读性会崩。材质是「透光不透字」的折中。
                .background(.regularMaterial)
                .navigationSplitViewColumnWidth(min: Theme.listMin, ideal: Theme.listIdeal, max: 660)
        } detail: {
            DetailView(model: model)
                .background(.regularMaterial)
                .navigationSplitViewColumnWidth(min: Theme.detailMin, ideal: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedKey) { _, _ in
            Task { await model.loadDetail() }
        }
        .sheet(isPresented: $model.showLog) {
            LogSheet(model: model)
        }
        // 没连上时不画骨架：三栏里露出的「capture 0 条」只是假装已连接，
        // 让人分不清「这个库是空的」还是「根本还没打开」。
        .opacity(model.phase == .ready ? 1 : 0)
        .overlay(alignment: .center) {
            if model.phase != .ready { connectCard }
        }
        .background(.regularMaterial)
        .animation(Theme.spring, value: model.phase)
    }

    // MARK: - 未连接

    private var connectCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: model.phase == .connecting)
                Text("mstore")
                    .font(.system(size: 20, weight: .semibold))
                Text(model.phase == .connecting ? model.status : "单文件存储 · 段表 + 位图索引")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(model.phase == .connecting ? "" : "选一个 store.db，或新建一个")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                Button("打开库…") { openPanel() }
                    .buttonStyle(.glass)
                Button("新建库…") { newPanel() }
                    .buttonStyle(.glassProminent)
            }

            if case .failed = model.phase {
                Text(model.status)
                    .font(Theme.mono(10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(28)
        .frame(width: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .transition(.blurReplace)
    }

    // MARK: - 面板

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

    private func newPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "app.db"
        panel.message = "新建一个空库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let rt = Sidecar.locateRuntime() else {
            model.log = "找不到 mstore 内核"
            model.showLog = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rt.node)
        p.arguments = [rt.cli, "init", url.path]
        try? p.run()
        p.waitUntilExit()
        model.open(path: url.path)
    }
}
