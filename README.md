# mstore-db

`mstore` 的 macOS 客户端。原生 AppKit + SwiftUI，**没有 WebView、没有 Electron**；
所有数据读写交给 `mstore` 的 Node sidecar，App 只负责展示。

**只支持 macOS 26。** 界面建立在 Liquid Glass 之上（`glassEffect` /
`GlassEffectContainer` / `scrollEdgeEffectStyle`）以及新的窗口合成行为，这些 API 和效果
在旧系统上都不存在。与其在 15 上退化成一堆灰底面板，不如明确不兼容。
`Package.swift` 里写着 `swift-tools-version: 6.2`、`platforms: [.macOS("26.0")]`。

![业务表 + 查询构建器](docs/screenshot-table.png)

```
┌──────────────────────────────────────┐
│ SwiftUI 三栏（本仓库）                 │  侧栏 / 列表+查询 / 详情
└───────────────┬──────────────────────┘
                │ stdio NDJSON（一行一请求，一行一响应）
┌───────────────▼──────────────────────┐
│ node cli.ts serve store.db            │  mstore 内核：单文件 + 段表 + group commit
└──────────────────────────────────────┘
```

## 跑起来

需要：macOS 26、Swift 6.2（Xcode 26）、Node ≥ 22.18、以及隔壁仓库 `mstore`。

```bash
# 1) 把内核放在同目录（默认会去 ../mstore 找 cli.ts）
git clone https://github.com/migoric/mstore.git ../mstore

# 2) 造一个演示库：3000 行业务 + 2000 条抓包 + 20 个 agent body
cd ../mstore && node bench/demo.ts --biz 3000 --cap 2000 --runs 20 && cd -

# 3) 构建运行
swift build
.build/debug/mstore-db ../mstore/data/demo.db
```

启动参数：

```bash
.build/debug/mstore-db <库路径> [--table] [--filter '<条件>'] [--dark]
```

| 参数 | 作用 |
|---|---|
| `<库路径>` | 要打开的库。不给则不自动连接，显示居中的连接卡（打开库… / 新建库…） |
| `--table` | 直接进「业务表」视图（CoW 页表 + 位图索引那一侧），而不是 KV 记录列表 |
| `--filter` | 预置查询条件，形如 `dept=R&D;level>=5;status=active,leave` |
| `--dark` | 强制深色外观 |

环境变量（不重建 App 就能换内核）：

| 变量 | 作用 |
|---|---|
| `MSTORE_NODE` | node 路径。缺省依次找 `/usr/local/bin/node`、`/opt/homebrew/bin/node`、`/usr/bin/node` |
| `MSTORE_CLI` | `cli.ts` 路径。缺省依次找 `../mstore/cli.ts`、`./mstore/cli.ts`、`~/Documents/projects/mstore/cli.ts` |

都找不到时会在窗口里直接告诉你设哪个变量，不用翻日志。

## 为什么是 stdio 而不是 HTTP

- **生命周期天然绑定**：App 退出，子进程跟着走，不会留孤儿进程占端口。
- **不会端口冲突**：同时开两个窗口读两个库也不打架。
- **没有鉴权问题**：只监听 localhost 的 HTTP 端口，任何本机进程都能连；一根只有父子进程
  持有的管道不行。
- **背压天然存在**：阻塞在写管道上就是背压，不用自己做队列。

协议是 NDJSON：请求带自增 `id`，响应回填同一个 `id`；读到同 `id` 之前忽略中间的推送帧。
第一行是内核主动推的 `hello`（pid / CRC 实现 / 初始统计），用来确认它真的起来了。

阻塞的管道读写全部丢到专用 `DispatchQueue`，**不占 Swift 并发的 cooperative pool**——
阻塞几毫秒不该把别人的 `await` 一起卡住。请求本身由 actor `StoreClient` 串行化，
正好对上内核的单写者假设。

## 三栏

| 栏 | 内容 |
|---|---|
| 侧栏 | `biz` / `capture` / `mock` / `agent` 四个命名空间 + 「业务表」入口；底部状态面板显示文件名、大小、**这次走的哪条路**、耗时、快照字节、shell/body/死段、CRC 实现；再下面是打开库 / 重新读取 / 自检三个按钮 |
| 中栏 | 记录列表或业务表行；顶部是标题 + 计数 + 延迟徽标 + 造数据 + 更多（自检 / 清空命名空间 / 清空业务表 / 跑压测）；业务表模式下挂查询构建器 |
| 详情 | 选中行的 JSON（正则高亮，超过 200KB 降级纯文本）、body 预览、自检结果 |

中栏和详情栏都是 `.regularMaterial`：窗口本身透明（玻璃才有东西可采样），
但内容区必须有材质，否则桌面上的文字会直接穿透列表。

侧栏底部那行是冷启动优化的仪表盘：

```
▮ 索引快照   32.3 ms          184.9 KB
shell 3   body 204   死段 0        zlib.crc32
```

走的若是逐页重放，图标和文字都会换，并显示原因（`no snapshot` / `stale (snap 12 ≠ biz 13)` /
`CRC mismatch` / `snapshot seg 41 missing or dead`）。**这是索引快照这个优化唯一的可见证据**，
所以放在第一屏。

### 查询构建器

不发明内核做不到的东西。`mstore` 的 `Filter` 只有四个自由度，UI 就只给五个操作符：

| 操作符 | 符号 | 值的形态 |
|---|---|---|
| 等于 | `=` | 枚举字段给下拉（值来自 `biz.stats().enumValues`），数值字段给输入框 |
| 属于其一 | `∈` | 逗号分隔多值 |
| 不小于 | `≥` | 数值 |
| 不大于 | `≤` | 数值 |
| 介于 | `↔` | 上下界两个数值 |

字段列表来自内核：枚举字段来自位图索引、数值字段来自 `Float64Array` 列，
由 `biz.info` 的响应给出，App 不硬编码 schema。

同一字段被多个条件命中时**后者覆盖前者**——内核的 `Filter` 每个字段只有一个槽位。
界面不偷偷合并，`descriptor` 显示最终生效的条件，一眼能看出哪个被盖掉了。

改条件后 120ms 防抖再发请求。3000 行上 `dept=R&D;level>=5` 命中 267 行，
首帧 1.61ms（含 JIT 预热），之后个位数到十几微秒。

## 退出时必须走 `close`

`applicationShouldTerminate` 返回 `.terminateLater`，先 `await client.close()` 再放行。
因为 **meta 和索引快照都写在 close 里**：直接 terminate 会丢掉最后一个快照，
下次启动就退回逐页重放（3000 行 166ms vs 命中快照 38ms，差 4 倍）。

## Liquid Glass 的实测结论

写在这里是因为一半的坑文档里看不出来：

| 做法 | 结果 |
|---|---|
| 窗口 `isOpaque = false` + `backgroundColor = .clear` + `titlebarAppearsTransparent` + `.fullSizeContentView` | **必须**。玻璃要对窗口后面的东西采样，一层不透明底色会把它变成白板 |
| `.glassEffect(.regular, in:)` 只用在固定位置的 `GlassPanel` / 连接卡 | 正确。每行列表都套玻璃会退化成噪点，还掉帧 |
| 内容区 `.background(.regularMaterial)` | **必须**。否则桌面文字穿透列表 |
| `.buttonStyle(.glass)` / `.glassProminent` | 纯文字按钮可以（未连接卡在用）；**图标按钮不行**——浅色材质上图标直接看不见，所以侧栏和中栏的动作按钮都是自绘的 `IconButton` / `MenuIcon` |
| 系统 `.toolbar` | **弃用**。工具条按钮会全挤到左侧，动作改成下沉到侧栏底部与中栏 header |
| `.backgroundExtensionEffect()` | **弃用**。深色模式下详情栏会被染成浅灰 |
| `.contentTransition(.numericText(value:))` | 计数变化用它，数字滚动而不是硬切 |
| `.transition(.blurReplace)` | 未连接 ↔ 已连接、空列表 ↔ 有内容 |

高级感来自**动的克制**而不是动画堆料：参数化弹簧统一走 `Theme.spring`
（`response 0.42` / `dampingFraction 0.84`），短促的状态反馈走 `Theme.quick`（`smooth 0.18`）。
延迟徽标按耗时染色（<1ms / <10ms / 更慢），不用文字解释就能看出快慢。

## 目录

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
docs/                    界面截图
```

**边界纪律**：`Core/` 不 import SwiftUI；`UI/` 不碰 `Process` 和管道；`AppModel` 是唯一的
可变状态入口；`[String: Any]` 只在 `StoreClient` 的 actor 内部存在，出去的必须是
`Payloads.swift` 里的 `Sendable` 值类型。这不是风格问题——Swift 6 的严格并发检查会直接拦住
跨 actor 传 `[String: Any]`。

## 协议

客户端只认这些 op（完整表见 `mstore` 仓库 README「stdio 协议」）：

```text
hello                              启动时主动推 {pid, crc, stats}
info / check                       库统计 / 自检
list / get / body                  记录、值、body（前 4KB，base64）
put / putbody / clear              KV 写入与按 ns 清空
biz.info / biz.query               页表与位图统计 / 位图查询
biz.get / biz.put / biz.del / biz.clear
backup / quit
```

`biz.query` 返回 `{matched, took_us, rows:[{key, rowid, value}]}`——`matched` 是全量命中数，
`rows` 只是前 `limit` 条，界面据此显示「命中 267 / 3000 行」。

## 截图

| 业务表（浅色） | 业务表（深色） |
|---|---|
| ![](docs/screenshot-table.png) | ![](docs/screenshot-table-dark.png) |

| KV 记录 | 未连接 |
|---|---|
| ![](docs/screenshot-records.png) | ![](docs/screenshot-idle.png) |

## 已知限制

- **只读**：界面不做写入编辑。写路径在 sidecar 里已经实现（`biz.put` / `biz.del` 等），
  只是没接编辑控件。
- **列表不虚拟化**：几千行会卡。上限由查询的 `limit` 挡住（默认 300）。
- **JSON 高亮有 200KB 上限**：超过就不着色，避免大 body 卡住主线程。
- **body 用 base64 过通道**：演示够用。真要传 5MB 大对象，应当只传 `{off, len}` 让 Swift 自己读盘。
- **一次只连一个库**：换库要先关掉当前的 sidecar。
- **无沙盒 / 无公证**：`swift build` 出来的裸可执行文件，只用于本地开发。
- **Swift 侧没有单元测试**：目前靠 `swift build` + 人工核对截图。
  纯逻辑部分（`QueryState.parse` / `payload()` / `FilterPayload.descriptor`）值得补 `swift-testing`。

## 相关

- 内核仓库：[`github.com/migoric/mstore`](https://github.com/migoric/mstore)
- 内核设计文档：`mstore/docs/design.md`（单文件形态、段表、清空三档、跨表索引、快照）
- 贡献与约定：本仓库 [`AGENTS.md`](AGENTS.md) / [`CONTRIBUTING.md`](CONTRIBUTING.md)

## 许可

MIT
