# mstore-db

`mstore` 的 macOS 客户端。原生 AppKit + SwiftUI，**没有 WebView、没有 Electron**；
所有数据读写交给 `mstore` 的 Node sidecar，App 只负责展示。

```
┌────────────────────────────┐
│ SwiftUI 界面（本仓库）       │  列表 / 详情 / 自检 / 压测
└───────────┬────────────────┘
            │ stdio NDJSON（一行一个请求，一行一个响应）
┌───────────▼────────────────┐
│ node cli.ts serve store.db │  mstore 内核：单文件 + 段表 + group commit
└────────────────────────────┘
```

## 为什么用 stdio 而不是 HTTP

- **生命周期天然绑定**：App 退出，子进程跟着走，不会留孤儿进程占端口。
- **零鉴权成本**：不监听端口 = 不需要 token、不担心被本机其他程序连。
- **协议极简**：一行 JSON 一个请求，带自增 `id`；读 body 时返回 base64（演示用）。

如果将来要压 RTT 到 1ms 以内，再换成 Unix domain socket；**当前瓶颈不在传输**，
而在「一次拿多少数据」——所以真正的优化是分页与字段裁剪（见 `docs/design.md` §9）。

## 构建与运行

需要：macOS 14+、Swift 6、Node ≥ 22.18、以及隔壁仓库 `mstore`。

```bash
# 1. 把 mstore 放在同目录（默认会去 ../mstore 找 cli.ts）
git clone https://github.com/migoric/mstore.git ../mstore

# 2. 编译运行
swift build
.build/debug/mstore-db ../mstore/data/bench.db
```

也可以指定路径，不依赖目录约定：

```bash
MSTORE_NODE=/usr/local/bin/node \
MSTORE_CLI=/path/to/mstore/cli.ts \
.build/debug/mstore-db /path/to/store.db
```

不带参数启动时，界面里可以「打开库…」或「新建库…」。

## 界面能做什么

工具条上有两个视图，对应内核里两种完全不同的读法：

**记录**（KV 命名空间）—— capture / biz / agent / mock 四类数据按 key 列出来

**业务表**（CoW 页表 + 位图索引）—— 带筛选器，走位图 `and` 而不是全表扫

| 区域 | 内容 |
|---|---|
| 左侧 | 库信息：文件大小、shell 段数、body 区段数、死段、各 ns 记录数、CRC 实现、提交统计 |
| 中间 | 视图内列表，点击选中；业务表模式显示「命中 N 条 · 显示 M 条」 |
| 右侧 | 选中记录的值（格式化 JSON）+ body 定位信息；「读 body 前 4KB」演示 offset 直读 |
| 筛选条 | 业务表模式下：部门 / 状态（枚举位图）+ level 上下限（数值区间），改一下立刻重查 |
| 工具条 | 造演示数据、跑压测、自检、清空当前 ns / 清空业务表、查看输出 |

业务表模式右下角会实时显示页表状态（`页 114 · 行 3000 · 重写 0 · 位图 8 · 占用 0.45 MB`），
查询耗时打在状态栏里——3000 行上通常个位数到十几微秒（首次查询含 JIT 预热，会到几百微秒）。

「清空」走的是段组标记（O(段数)），不是逐行删——所以几万条也是毫秒级。
「造演示数据」调的是 `mstore` 的 `bench/demo.ts`：3000 行业务 + 2000 条抓包 + 20 个 agent body，
1.6 秒造完，三个视图都有东西可看。

## 协议

客户端只认下面这些 op（完整表见 `mstore` 仓库 README）：

```text
hello                        启动时主动推 {pid, crc, stats}
info / check                 库统计 / 自检
list / get / body            记录、值、body（base64）
put / putbody / clear        KV 写入与按 ns 清空
biz.info / biz.query        页表与位图统计 / 位图查询（filter + limit）
biz.get / biz.put / biz.del / biz.clear
backup / quit
```

`biz.query` 返回 `{matched, took_us, rows:[{key, rowid, value}]}` —— `matched` 是全量命中数，
`rows` 只是前 `limit` 条，界面据此显示「命中 200 · 显示 200」。

## 已知限制（v0）

- **不做写入编辑**：界面目前只读。写路径在 CLI / sidecar 里已经实现
  （`put` / `putbody` / `biz.put` / `biz.del` / `biz.clear`），只是还没接上编辑控件。
- **body 用 base64 过通道**：演示够用，真要传 5MB 大对象应当只传 `{off, len}` 让 Swift 自己读盘。
- **无沙盒/公证**：`swift build` 出来的裸可执行文件，只用于本地开发。
- **一次只连一个库**。

## 相关

- 内核仓库：`github.com/migoric/mstore`
- 设计文档：`docs/design.md`（单文件形态、段表、清空三档、跨表索引、可读性预算等）

## License

MIT
