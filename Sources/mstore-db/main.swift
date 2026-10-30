import AppKit

// 顶层代码只能放在 main.swift 里（Swift 的约定），所以入口留在这里，
// AppDelegate 与全部视图在各自文件里。
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
