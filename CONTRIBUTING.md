# Contributing

欢迎提交 issue 和 PR。这个仓库很小（约 2100 行 Swift），门槛主要在**平台前提**和
**视觉验收**上，说明如下。

## 开工之前

- 先读 [`AGENTS.md`](AGENTS.md)：结构、依赖方向、并发纪律、玻璃态的实测结论、已知坑。
- 界面改动必须在 **macOS 26** 上验证。低版本连编译都过不了（`platforms: [.macOS("26.0")]`），
  这不是待修复的兼容性问题，是设计选择。
- 行为改动请先开 issue 对齐。这个项目对「加一层抽象」很保守。

## 环境

| 需要 | 版本 |
|---|---|
| macOS | **26**（Liquid Glass 的 API 与窗口合成行为） |
| Xcode / Swift | 26 / 6.2（`swift-tools-version: 6.2`） |
| Node | ≥ 22.18（sidecar 直接跑 `.ts`） |
| 内核 | 隔壁仓库 [`mstore`](https://github.com/migoric/mstore)，默认在 `../mstore` |

```bash
git clone https://github.com/migoric/mstore.git ../mstore
cd ../mstore && node bench/demo.ts --biz 3000 --cap 2000 --runs 20 && cd -

swift build
.build/debug/mstore-db ../mstore/data/demo.db --table
```

不需要 CocoaPods / SPM 依赖——`Package.swift` 里没有任何 `dependencies`，请保持这样。

## PR 要求清单

- [ ] `swift build` 零 error、零 warning（`swift build 2>&1 | grep -E "error|warning"` 无输出）
- [ ] 界面改动附**浅色与深色各一张**截图；两者都看，玻璃的对比度问题在浅色下看不出来
- [ ] 动了状态机就贴测试步骤（打开哪个库、点了什么、期望看到什么）
- [ ] 动了查询逻辑就跑一次 `--filter` 验证链路真的通：
      `.build/debug/mstore-db <lib> --table --filter 'dept=R&D;level>=5'`
- [ ] 动了协议就同时在 `mstore` 仓库补 `test/protocol.test.ts` 用例，并说明两边的合并顺序
- [ ] 提交信息符合 Conventional Commits（见 AGENTS.md）

## 代码风格

- 依赖方向只能是 `UI → Model → Core`。`Core/` 不 import SwiftUI，`UI/` 不碰 `Process`。
- 颜色、字号、间距、圆角、动画参数一律走 `Theme`。
- 动画只用 `Theme.spring`（`0.42 / 0.84`）与 `Theme.quick`（`smooth 0.18`）。
- `.glassEffect` 只用在固定位置的面板，不进行、不叠加 `shadow`。
- 跨 actor 只传 `Payloads.swift` 里的 `Sendable` 值类型。
- 注释写「为什么」。反直觉的做法（比如「玻璃按钮在这里不能用」）把实测结论留在代码旁边。

## 视觉验收

没有快照测试，所以视觉改动靠人眼。请按这四种状态各看一遍：

| 状态 | 命令 | 注意 |
|---|---|---|
| 业务表 · 浅色 | `--table` | 玻璃是否有东西可采样、文字对比度 |
| 业务表 · 深色 | `--table --dark` | 详情栏是否被染浅、分隔线是否还看得见 |
| KV 记录 | 无参数 | 桌面文字是否穿透列表 |
| 未连接 | 不带库路径 | 连接卡是否居中、三栏骨架是否被正确隐藏 |

窗口**不要**为了截图改尺寸逻辑——`setFrameAutosaveName` 会记住上次大小，
所以截图前先确认窗口是常规尺寸。

## 报 Bug

用 issue 模板，务必包含：

1. macOS 版本、Xcode / Swift 版本（`swift --version`）
2. `node -v`
3. 复现步骤（命令 + 点了哪里）
4. 期望行为 vs 实际行为，最好带截图
5. 如果是「连不上库」：贴侧栏底部状态面板的内容，以及是否设了 `MSTORE_NODE` / `MSTORE_CLI`

**不要**贴真实业务数据。样本库用 `mstore` 的 `bench/demo.ts` 造。

## 安全

见 [`SECURITY.md`](SECURITY.md)。这个 App 不联网、不沙盒、以普通用户权限读写本地文件，
威胁模型很窄。

## 许可

提交即表示同意以 [MIT](LICENSE) 许可发布你的贡献。
