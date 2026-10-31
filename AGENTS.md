# AGENTS.md

给在这个仓库里干活的人（或 agent）看的操作手册。README 讲「这是什么、怎么跑」，
这里讲**动手时必须知道的事**。

这个仓库只有两千行 Swift，但它是**并发 + 玻璃态 + 子进程**三件事交叉的地方，
踩坑成本比行数高得多。先记住四条：

1. **只支持 macOS 26**，不要为了「兼容」加 `if #available` 降级分支。
2. **`.glassEffect` 只用在固定位置的面板上**，列表行里套玻璃会既丑又掉帧。
3. **跨 actor 只传 `Sendable` 值类型**。`[String: Any]` 不出 `StoreClient`。
4. **退出必须走 `client.close()`**，快照与 meta 都写在 close 里。

---

## 结构

```
Sources/mstore-db/
  main.swift              顶层代码（NSApplication 启动 + app.run()）
  AppMain.swift           AppDelegate：窗口、标题栏、命令行参数、terminateLater
  Core/
    Payloads.swift        Sendable 值类型：Namespace / Record / TableRow /
                          FilterPayload / QueryOutcome / StoreSummary / TableSummary / Handshake
    Sidecar.swift         子进程与管道：定位 node 与 cli.ts、同步交换、行缓冲
    StoreClient.swift     actor。所有 op 的方法 + 一个 call(_:) + 专用串行队列
  Model/
    AppModel.swift        @MainActor，唯一可变状态入口
    QueryState.swift      QueryOp / QueryCondition / QueryState（payload、descriptor、parse）
  UI/
    Theme.swift           尺寸、圆角、弹簧、延迟染色、可复用小组件
    RootView.swift        NavigationSplitView 三栏、连接卡、打开/新建面板
    SidebarView.swift     命名空间 + 业务表入口 + 底部状态面板 + 动作按钮
    RecordListView.swift  记录列表 / 表格 + header + 更多菜单
    QueryBar.swift        条件 chip 行
    DetailView.swift      JSON 详情 + 自检 + LogSheet
    JSONHighlight.swift   正则着色
```

**依赖方向只能一路向下**：`UI` → `Model` → `Core`，反过来不行。
`Core/` 里 import SwiftUI 是错的（想复用颜色就把值提到 `Theme`）。
`UI/` 里直接 `Process()` 也是错的（要加 op 就在 `StoreClient` 上加方法）。

## 命令

```bash
swift build                                     # 编译。零依赖，没有 Package.resolved
.build/debug/mstore-db <lib> [--table] [--filter '<cond>'] [--dark]

# 造演示库（在 mstore 仓库里）
cd ../mstore && node bench/demo.ts --biz 3000 --cap 2000 --runs 20

# 截图（浅色 / 深色 / 记录 / 未连接），用来人工核对玻璃效果
.build/debug/mstore-db ../mstore/data/demo.db --table &
swift build 2>&1 | grep -E "error|warning"      # 提交前必须干净
```

`--filter` 不是为了炫技：没有它就没法在无人操作的情况下验证查询链路。
**「UI 上能点」和「查询真的走位图索引」是两件事**，后者必须能被脚本证明。

## 代码约定

### 并发（Swift 6 严格检查）

- `AppModel` 是 `@MainActor` 的。所有改状态的方法都在 MainActor 上。
- `StoreClient` 是 `actor`。所有请求串行——正好对上内核的单写者。
- 阻塞调用（读管道、`waitUntilExit`）必须经 `onQueue { }` 丢到专用 `DispatchQueue`，
  **不要**让它跑在 cooperative pool 上——那会卡住别人的 `await`。
- `Task.detached` 里**不要捕获 `@MainActor self`**。错误是
  `sending 'self' risks causing data races`。正确写法是让逻辑变成
  `nonisolated static func`，外层 `Task { let r = await X.run(...); self.xxx = r }`。
- `?? (await ...)` 会报 `'.async' call in an autoclosure`。写 `if let / else`。

### Sendable 边界

`[String: Any]` 从管道里解析出来就在 actor 内部消化掉，转成 `Payloads.swift` 里的
`struct` 之后再出去。这条纪律不是洁癖：Swift 6 会直接编译失败，绕过去只能靠
`@unchecked Sendable`，那是给自己埋雷。

`Sidecar` 是 `@unchecked Sendable`——它内部用 `NSLock` 保护了共享状态，
这是唯一的例外，改动它时要重新论证一遍。

### UI

- 颜色/字号/间距/圆角/动画参数**一律走 `Theme`**。散落的 `.font(.system(size: 11))`
  是后续对不齐的根源。
- 动画只用 `Theme.spring` 和 `Theme.quick`。新增第三组参数前先想清楚为什么这两组不够。
- 图标按钮用 `IconButton` / `MenuIcon`，不要用 `.buttonStyle(.glass)`——
  玻璃按钮在浅色材质上图标不可见（实测）。
- 不要在 `List` 行里加 `glassEffect`、`shadow`、`background`。行是高频绘制的。
- `List(selection:)` 的 tag 类型必须和绑定的类型一致（`String?` / `AppModel.Mode?`）。

### 文件布局的硬约束

- **顶层语句只能写在 `main.swift`**。放别处会报
  `expressions are not allowed at the top level`。
- `AppMain.swift` 里定义了 `AppDelegate`，`main.swift` 只负责
  `NSApplication.shared` + `app.run()`。保持这个分工，别把启动逻辑写回 `main.swift`。

## 改动纪律

### 加一个协议 op

1. `StoreClient` 加方法，`call([...])`，把响应解析成 `Payloads.swift` 里的值类型。
2. 需要新字段就在对应的 `struct` 上加，**不要在 UI 里二次解析 JSON**。
3. 在 `mstore` 仓库的 `cli.ts` 里加服务端分支，并补 `test/protocol.test.ts` 用例——
   协议的对错由内核那侧的测试保证，这边只保证「发对了帧」。
4. 两边同时提 PR，先合内核。

### 改窗口 / 材质

改之前先读 README 的「Liquid Glass 的实测结论」表。已经踩过的坑不要再踩一遍：

| 症状 | 原因 |
|---|---|
| 玻璃变成一整块白板 | 窗口 `isOpaque` 还是 true，或者 `backgroundColor` 不是 `.clear` |
| 桌面文字穿透列表 | 内容区缺 `.regularMaterial` |
| 深色下详情栏变浅灰 | `.backgroundExtensionEffect()` |
| 工具条按钮全挤到左边 | 用系统 `.toolbar` 而不是自绘 header |
| 图标按钮看不见 | `.buttonStyle(.glass)` 用在图标上 |
| 标题栏截断侧栏材质 | 缺 `titlebarAppearsTransparent` + `.fullSizeContentView` |

### 退出路径

`applicationShouldTerminate` 返回 `.terminateLater`，等 `client.close()` 完成再
`reply(toApplicationShouldTerminate: true)`。**不要**改成 `.terminateNow`：
close 里写 meta 和索引快照，跳过它下次启动必然走逐页重放（慢 4 倍）。

## 测试要求

现状：Swift 侧已有 `swift-testing` 纯逻辑单测，UI 仍靠 `swift build` + 四张截图人工核对。
继续补测试时按这个优先级：

1. `QueryState.parse` —— 纯函数，输入字符串输出条件数组，最容易锁住也最容易写错
   （`>=` 必须先于 `=` 匹配，否则 `level>=5` 会被解析成 `level>` 等于 `5`）。
2. `FilterPayload.descriptor` —— 界面文案来源于它，错了用户看不出来。
3. `Payloads` 的 JSON 解码 —— 内核改字段名时这里必须报错而不是静默变空。

用 `swift-testing`（Swift 6.2 自带），建一个 `Tests/mstore-dbTests` target。
**不要**为了测试把 `@MainActor` 类改成全局可变单例。

验收一个 UI 改动至少要做到：

```bash
swift build 2>&1 | grep -E "error|warning"   # 零输出
# 四种状态各截一张，人眼看玻璃、对齐、对比度
swift run mstore-db ../mstore/data/demo.db --table
swift run mstore-db ../mstore/data/demo.db --table --dark
swift run mstore-db ../mstore/data/demo.db
swift run mstore-db
```

深色模式**必须**单独看一遍：玻璃的对比度问题在浅色下完全看不出来。

## 已知坑

| 坑 | 说明 |
|---|---|
| `expressions are not allowed at the top level` | 顶层代码只能在 `main.swift` |
| `sending 'self' risks causing data races` | `Task.detached` 捕获了 `@MainActor self`；改成 `nonisolated static` |
| `'.async' call in an autoclosure` | `?? (await ...)`；改 `if let / else` |
| `subtitle` 缺 return | `switch` 表达式里混了 `guard...else return`，每个 case 都要显式 `return` |
| 侧栏 `List` 里选中项不跟随 | `selection` 的 get 在 `phase != .ready` 时返回 `nil`，这是故意的（未连接时不该有选中） |
| 详情栏空白 | `doReload()` / `doQuery()` 之后要自动选中第一行并 `loadDetail()` |
| 换命名空间列表没重建 | `content.id(model.mode)` 是故意的，去掉会保留滚动位置并让动画失去意义 |

## 提交规范

Conventional Commits，中文正文，与 `mstore` 仓库一致：

```
feat: 三栏 + 查询构建器；macOS 26 Liquid Glass
fix(ui): 图标按钮换自绘，玻璃按钮在浅色材质上不可见
refactor: 按 Core/Model/UI 分层，Sendable 值类型出入 actor
docs: README 重写，补 --table / --filter / --dark
```

一个提交做一件事。**UI 重构与行为变更分开提**——截图对比会很乱。

不提交 `.build/`、`.swiftpm/`、`.DS_Store`（`.gitignore` 已覆盖）。

---

有任何一条与实际代码不符，改这个文件，别绕过去。
