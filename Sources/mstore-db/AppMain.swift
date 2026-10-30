import AppKit
import SwiftUI

/// 进程入口。
///
/// 还是用 AppKit 起窗口而不是 SwiftUI 的 `@main App`：SwiftPM 直接跑的可执行文件
/// 没有 .app bundle，AppKit 方式能稳定拿到前台窗口、激活状态和窗口级样式
/// （透明标题栏、内容延伸到标题栏），这些正是玻璃态界面需要的。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: RootView(model: model))
        hosting.wantsLayer = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "mstore"
        // 标题栏透明 + 内容延伸到标题栏：玻璃要在「一整块连续的背景」上才好看，
        // 一条不透明的标题栏会把侧栏的材质硬生生截断。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        // 窗口自己不画底色：Liquid Glass 要对「窗口后面的东西」采样，
        // 一层不透明的 NSWindow backgroundColor 会把采样对象换成一整块纯色，玻璃就变成白板了。
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.contentMinSize = NSSize(width: Theme.windowMinWidth, height: Theme.windowMinHeight)
        window.setFrameAutosaveName("mstore-db-main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 命令行：mstore-db <路径> [--table]
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if let i = args.firstIndex(of: "--filter"), i + 1 < args.count {
            model.pendingFilter = args[i + 1]
        }
        if let path = args.first(where: { !$0.hasPrefix("--") }) {
            if args.contains("--table") { model.pendingTableMode = true }
            model.open(path: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 退出前必须让 sidecar 走一次 `quit`：meta 和索引快照都写在 close 里，
    /// 直接 terminate 会丢掉最后一个快照，下次启动就退回逐页重放。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .ready else { return .terminateNow }
        let client = model.client
        Task.detached {
            await client.close()
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
