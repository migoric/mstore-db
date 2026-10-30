# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.2.0] — 2026-10-31

**只支持 macOS 26。** 界面整体改写成 Liquid Glass 三栏，加入查询构建器，
内部按 `Core / Model / UI` 重新分层。命令行参数 `--biz` 更名为 `--table`。

### Added
- **Liquid Glass 界面**：透明窗口（`isOpaque = false` + `clear` 背景 +
  `titlebarAppearsTransparent` + `.fullSizeContentView`），固定位置面板用
  `.glassEffect(.regular, in:)`，内容区用 `.regularMaterial` 保证文字不被桌面穿透。
  未连接时显示居中连接卡（`.glassEffect` + `.blurReplace`）。
- **三栏布局**：`NavigationSplitView` + `.balanced`。侧栏（命名空间 / 业务表 / 底部状态面板）、
  中栏（列表 + header）、详情（JSON + 自检）。
- **查询构建器**：条件 chip 行，五个操作符（`=` / `∈` / `≥` / `≤` / `↔`）。
  字段与可选枚举值来自内核的 `biz.info`（`enumValues` / `numFields`），App 不硬编码 schema。
  改条件后 120ms 防抖重查。
- **命令行**：`--table` 直接进业务表视图、`--filter '<cond>'` 预置查询条件
  （`dept=R&D;level>=5;status=active,leave`）、`--dark` 强制深色。
- **侧栏状态面板**：文件名、大小、**这次走的哪条路**（索引快照 / 逐页重放）、耗时、
  快照字节、shell/body/死段、CRC 实现。走重放时显示原因
  （`no snapshot` / `stale` / `CRC mismatch` / 段丢失）。
- `Theme`：尺寸、圆角、弹簧参数（`spring 0.42/0.84`、`quick smooth 0.18`）、
  延迟染色（`<1ms` / `<10ms` / 更慢），以及 `GlassPanel` / `StatRow` / `LatencyBadge` /
  `CountBadge` / `StatusDot` / `IconButton` / `MenuIcon` / `EmptyHint`。
- `JSONHighlight`：四类 token 正则着色，超过 200KB 自动降级为纯文本。
- 中栏 header 的「造演示数据」与「更多」菜单（自检 / 清空命名空间 / 清空业务表 / 跑压测）。
- 详情栏在列表加载或查询后自动选中第一行。

### Changed
- 目录重构为 `Core/`（Payloads、Sidecar、StoreClient）、`Model/`（AppModel、QueryState）、
  `UI/`（Theme、RootView、SidebarView、RecordListView、QueryBar、DetailView、JSONHighlight）。
  原 `Views.swift` 拆分删除。
- `AppModel` 重写为 `@MainActor` 状态机：`Phase`（idle/connecting/ready/failed）×
  `Mode`（`records(Namespace)` / `table`），带 120ms 防抖与请求串行。
- `--biz` 更名为 `--table`（**破坏性**：旧脚本需要改）。
- 工具条动作下沉到侧栏底部与中栏 header。系统 `.toolbar` 已弃用——
  按钮会全挤到左侧。

### Fixed
- 玻璃按钮（`.buttonStyle(.glass)` / `.glassProminent`）上的图标在浅色材质上不可见 →
  改自绘 `IconButton` / `MenuIcon`。纯文字按钮仍可用系统样式。
- `.backgroundExtensionEffect()` 在深色模式下把详情栏染成浅灰 → 去掉。
- 桌面文字穿透列表 → 内容区补 `.regularMaterial`。
- 未连接时露出「capture 0 条」的空骨架，分不清「空库」还是「没打开」 → 三栏
  `.opacity(phase == .ready ? 1 : 0)`，未连接只显示连接卡。
- 详情栏默认空白 → 加载后自动选中首行。

### Notes
- `swift-tools-version: 6.2`，`platforms: [.macOS("26.0")]`。低版本不兼容，
  没有降级分支。
- 退出时 `applicationShouldTerminate` 返回 `.terminateLater`，等 `close()` 写完
  meta 与索引快照再放行。跳过它会退回逐页重放（慢 4 倍）。

## [0.1.0] — 2026-10-30

首个版本：能连内核、能看数据。

### Added
- AppKit + SwiftUI 单窗口，AppKit 起窗口（SwiftPM 可执行文件没有 .app bundle，
  AppKit 才能稳定拿到前台窗口与窗口级样式）。
- 与 `mstore` 的 stdio NDJSON 通道：一行一请求、一行一响应、自增 `id`，
  启动时内核主动推 `hello`。
- 定位内核：`MSTORE_NODE` / `MSTORE_CLI` 环境变量优先，否则按目录约定找。
- 四个命名空间的记录列表 + 详情（格式化 JSON / body 前 4KB）。
- 业务表视图：位图筛选（部门 / 状态 / level 上下限）、页表统计、
  「命中 N / 显示 M」。
- 库信息面板：文件大小、段统计、各 ns 记录数、CRC 实现、提交统计。
- 自检、清空命名空间、清空业务表、造演示数据、跑压测。
