# Security Policy

## 先看清楚威胁模型

`mstore-db` 是一个**本地只读查看器**。它：

- **不联网**。没有任何 socket、没有 HTTP 客户端、没有遥测。
- **不沙盒**。以你的用户权限运行，能读写你能读写的任何文件。
- **不加密**。展示的是 `mstore` 库的明文内容。
- **会启子进程**：`node cli.ts serve <库路径>`，路径来自命令行参数或文件选择面板。

因此以下**不算**漏洞：

| 不算漏洞 | 说明 |
|---|---|
| 打开库后能读到库里的数据 | 这就是它的功能。库的权限由文件系统决定（`chmod 600`） |
| 库文件是明文 | `mstore` 不提供加密，需要保密请用 FileVault |
| 无代码签名 / 无公证 | `swift build` 出来的裸可执行文件，只用于本地开发 |
| 子进程继承了环境变量 | `Process` 的默认行为，包括 `MSTORE_NODE` / `MSTORE_CLI` |

## 报告漏洞

**请不要开公开 issue。**

用 GitHub 的 [私密漏洞报告](https://github.com/migoric/mstore-db/security/advisories/new)，
或直接联系仓库维护者（GitHub 主页有邮箱）。

请包含：受影响的 commit、复现步骤、影响判断、`swift --version` 与 macOS 版本。

## 响应

- 3 个工作日内确认收到
- 确认后给出评估结论与修复时间窗（通常 7–30 天）
- 修复发布后，在你的同意下于 advisory 里致谢

## 我们确实关心的类别

- **路径注入**：`MSTORE_CLI` / 命令行参数 / 文件面板返回的路径被拼进
  `Process.arguments` 或 shell 导致执行了非预期程序。当前实现是
  `process.executableURL = node` + `arguments = [cli, "serve", path]`，**不经过 shell**——
  破坏这一点就是漏洞。
- **协议解析越界**：`Sidecar` 的行缓冲在超长行、非法 JSON、`id` 缺失时的行为。
  当前不会崩，但大量畸形帧导致内存无限增长（缓冲只按 `\n` 切分，无上限）是真问题。
- **读取内核返回的恶意数据导致崩溃**：例如 `biz.query` 返回的字段类型与预期不符时，
  `Payloads.swift` 的解码路径会不会强解包崩掉。
- **子进程逃逸**：App 退出后仍留存的 `node` 进程（当前 `applicationShouldTerminate`
  走 `close` + `terminate`，不留孤儿——破坏这条就是漏洞）。

## 加固建议（给使用者）

```bash
chmod 600 store.db          # 库的权限收窄
# 只用你自己 clone 的 cli.ts：MSTORE_CLI 指向不受信任的脚本等于让它执行任意代码
```
