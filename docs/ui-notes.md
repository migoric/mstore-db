# UI 与运行时笔记

README 只讲功能与指标。这里放「为什么要这么做」以及踩过的坑——它们在改界面时会用到，
但不该占首页。

## 为什么是 stdio 而不是 HTTP

- **生命周期天然绑定**：App 退出，子进程跟着走，不会留孤儿进程占端口。
- **不会端口冲突**：同时开两个窗口读两个库也不打架。
- **没有鉴权问题**：只监听 localhost 的 HTTP 端口，任何本机进程都能连；一根只有父子进程
  持有的管道不行。
- **背压天然存在**：阻塞在写管道上就是背压，不用自己做队列。

阻塞的管道读写全部丢到专用 `DispatchQueue`，**不占 Swift 并发的 cooperative pool**——
阻塞几毫秒不该把别人的 `await` 一起卡住。请求本身由 actor `StoreClient` 串行化，
正好对上内核的单写者假设。

## Liquid Glass 的实测结论

写在这里是因为一半的坑文档里看不出来：

| 做法 | 结果 |
|---|---|
| 窗口 `isOpaque = false` + `backgroundColor = .clear` + `titlebarAppearsTransparent` + `.fullSizeContentView` | **必须**。玻璃要对窗口后面的东西采样，一层不透明底色会把它变成白板 |
| `.glassEffect(.regular, in:)` 只用在固定位置的 `GlassPanel` / 连接卡 | 正确。每行列表都套玻璃会退化成噪点，还掉帧 |
| 内容区 `.background(.regularMaterial)` | **必须**。否则桌面文字穿透列表 |
| `.buttonStyle(.glass)` / `.glassProminent` | 纯文字按钮可以；**图标按钮不行**——浅色材质上图标直接看不见，所以动作按钮都是自绘的 `IconButton` / `MenuIcon` |
| 系统 `.toolbar` | **弃用**。工具条按钮会全挤到左侧，动作改成下沉到侧栏底部与中栏 header |
| `.backgroundExtensionEffect()` | **弃用**。深色模式下详情栏会被染成浅灰 |
| `.contentTransition(.numericText(value:))` | 计数变化用它，数字滚动而不是硬切 |
| `.transition(.blurReplace)` | 未连接 ↔ 已连接、空列表 ↔ 有内容 |

高级感来自**动的克制**而不是动画堆料：参数化弹簧统一走 `Theme.spring`
（`response 0.42` / `dampingFraction 0.84`），短促的状态反馈走 `Theme.quick`（`smooth 0.18`）。
延迟徽标按耗时染色（<1ms / <10ms / 更慢），不用文字解释就能看出快慢。

## 目录与边界纪律

```
Sources/mstore-db/
  main.swift             顶层代码（NSApplication 启动）。Swift 规定顶层语句只能放这里
  AppMain.swift          AppDelegate：窗口样式、透明标题栏、命令行参数、退出时先关 sidecar
  Core/
    Payloads.swift       跨 actor 边界的值类型。`[String: Any]` 不出 actor
    Sidecar.swift        stdio 通道：定位 node / cli.ts、同步读写、行缓冲
    StoreClient.swift    actor。请求串行；阻塞读写丢到专用队列
  Model/
    AppModel.swift       @MainActor 状态机：Phase（idle/connecting/ready/failed）× Mode（records/table）
    QueryState.swift     查询条件 → FilterPayload；命令行条件解析
  UI/
    Theme.swift          尺寸、圆角、弹簧参数、延迟染色；GlassPanel / StatRow / IconButton 等
    RootView.swift       NavigationSplitView 三栏 + 未连接时的连接卡
    SidebarView.swift    命名空间列表 + 底部状态面板 + 动作按钮
    RecordListView.swift 列表 / 表格 + header
    QueryBar.swift       条件 chip 行
    DetailView.swift     JSON 详情 + 自检结果 + 清空确认
    JSONHighlight.swift  四类 token 正则着色（>200KB 不着色）
Tests/                   纯逻辑单测（swift-testing）
tools/
  bundle.sh              组 .app + ad-hoc 签名 + 打 zip
  make-icon.py           生成 AppIcon.icns
  protocol-check.mjs     对内核跑一遍协议契约
```

**边界纪律**：`Core/` 不 import SwiftUI；`UI/` 不碰 `Process` 和管道；`AppModel` 是唯一的
可变状态入口；`[String: Any]` 只在 `StoreClient` 的 actor 内部存在，出去的必须是
`Payloads.swift` 里的 `Sendable` 值类型。这不是风格问题——Swift 6 的严格并发检查会直接拦住
跨 actor 传 `[String: Any]`。

## 零 warning 的正确验法

本地增量构建会跳过未改动的文件，warning 可能只在新克隆上出现。验证「零 warning」
必须用干净构建：

```bash
swift build --disable-sandbox --scratch-path /tmp/mstore-clean
```

`--disable-sandbox` 不是可选项：SwiftPM 编译 manifest 时会自己套一层 `sandbox-exec`，
在受限 shell 里会报 `sandbox_apply: Operation not permitted`，而错误信息显示的是
「Invalid manifest」，看起来像 `Package.swift` 写错了。
