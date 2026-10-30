import AppKit
import SwiftUI

/// 用 AppKit 起窗口而不是 SwiftUI 的 @main App：
/// SwiftPM 直接跑的可执行文件没有 .app bundle，AppKit 方式能稳定拿到前台窗口和激活状态。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mstore-db"
        window.contentView = hosting
        window.setFrameAutosaveName("mstore-db-main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 命令行可以带一个库路径直接打开
        if let path = CommandLine.arguments.dropFirst().first {
            model.open(path: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.disconnect()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
