## 这个 PR 做了什么

<!-- 一句话说清。如果修的是 issue，写 Closes #123 -->

## 为什么这么做

<!-- 讲取舍。特别是：为什么不需要改内核？如果改了，两个仓库的合并顺序是什么？ -->

## 改动范围

- [ ] `Core/`（协议、sidecar、值类型）
- [ ] `Model/`（状态机、查询条件）
- [ ] `UI/`（视图、主题）
- [ ] 命令行参数
- [ ] 工具 / CI
- [ ] 文档

## 门禁自查

- [ ] `swift build` 零 error、零 warning（`swift build 2>&1 | grep -E "error|warning"` 无输出）
- [ ] `node tools/protocol-check.mjs ../mstore/cli.ts <lib>` 通过（动了协议必跑）
- [ ] 查询链路验证过：`.build/debug/mstore-db <lib> --table --filter 'dept=R&D;level>=5'`
- [ ] 没有引入 `#available` 降级分支（本项目只做 macOS 26）
- [ ] 没有引入 SPM 依赖（`Package.swift` 保持零 dependencies）

## 截图

界面改动**必须**附浅色与深色各一张——玻璃的对比度问题在浅色下看不出来。

| | 浅色 | 深色 |
|---|---|---|
| 改动前 |  |  |
| 改动后 |  |  |

## 在四种状态下都看过

- [ ] `--table`（业务表 · 浅色）
- [ ] `--table --dark`（业务表 · 深色）
- [ ] 无参数（KV 记录，检查桌面文字是否穿透列表）
- [ ] 不带库路径（未连接的连接卡）

## 其他

<!-- 已知问题、后续计划、需要 reviewer 特别看的地方 -->
