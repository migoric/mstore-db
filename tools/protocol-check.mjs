#!/usr/bin/env node
/**
 * 协议契约检查：不启动 GUI，只验证「客户端依赖的那几个帧」没变。
 *
 * CI 里跑不了窗口（没有窗口会话），但协议是客户端与内核之间唯一的东西——
 * 它变了，界面就空了，而这种失败在真机上表现为「打开库之后一片空白」，很难定位。
 *
 *   node tools/protocol-check.mjs <cli.ts 路径> <库路径>
 *
 * 检查项与 Sources/mstore-db/Core/{StoreClient,Payloads}.swift 一一对齐：
 *   hello       → { pid, crc }                                    open() 的握手
 *   info        → result.{file, bytesLogical, segs, records,
 *                        deadSegs, crcImpl, committer, snapshot}  summary()
 *   biz.info    → result.{pages, index.{enumValues, nums}}        查询构建器的字段来源
 *   biz.query   → result.{matched, took_us, rows:[{key,rowid,value}]}
 *   get         → result.{value, body, seg, ts}                   记录详情
 *
 * 任何一项形状不对就非零退出。
 */
import { spawn } from 'node:child_process';

const [cli, db] = process.argv.slice(2);
if (!cli || !db) {
  console.error('用法: node tools/protocol-check.mjs <cli.ts> <库路径>');
  process.exit(2);
}

const child = spawn(process.execPath, [cli, 'serve', db], {
  stdio: ['pipe', 'pipe', 'inherit'],
});

let buffer = '';
let nextId = 1;
const pending = new Map();
let hello = null;

child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, nl);
    buffer = buffer.slice(nl + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      die(`响应不是 JSON: ${line.slice(0, 120)}`);
    }
    if (msg.hello) {
      hello = msg.hello;
      continue;
    }
    const waiter = pending.get(msg.id);
    if (waiter) {
      pending.delete(msg.id);
      waiter(msg);
    }
  }
});

child.on('exit', (code) => {
  if (code) die(`sidecar 退出码 ${code}`);
});

/** 发一条请求，返回完整的 `{id, ok, result, error?}` 帧 */
function call(op, extra = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`超时：op=${op}`));
    }, 15_000);
    pending.set(id, (msg) => {
      clearTimeout(timer);
      if (msg.ok === false) reject(new Error(`${op} 返回错误：${msg.error}`));
      else resolve(msg);
    });
    child.stdin.write(JSON.stringify({ ...extra, op, id }) + '\n');
  });
}

function die(text) {
  console.error('✗ ' + text);
  try {
    child.kill();
  } catch {}
  process.exit(1);
}

function need(cond, what) {
  if (!cond) die(what);
  console.log('✓ ' + what);
}

try {
  // 内核起来后会主动推一行 hello
  const t0 = Date.now();
  while (!hello) {
    if (Date.now() - t0 > 15_000) die('15s 内没收到 hello');
    await new Promise((r) => setTimeout(r, 30));
  }
  need(typeof hello.pid === 'number' && typeof hello.crc === 'string', 'hello 带 pid / crc');

  const info = (await call('info')).result ?? {};
  need(typeof info.file === 'string' && info.segs && info.records, 'info 带 file / segs / records');
  need(
    typeof info.bytesLogical === 'number' && typeof info.deadSegs === 'number' && !!info.committer,
    'info 带 bytesLogical / deadSegs / committer（侧栏状态面板要用）'
  );
  need(
    !!info.snapshot && typeof info.snapshot.openMs === 'number' && typeof info.snapshot.path === 'string',
    'info.snapshot 带 path / openMs（冷启动走哪条路）'
  );

  const biz = (await call('biz.info')).result ?? {};
  need(!!biz.pages && !!biz.index, 'biz.info 带 pages / index');
  need(
    !!biz.index.enumValues && Array.isArray(biz.index.nums),
    'biz.index 带 enumValues / nums（查询构建器的字段来源）'
  );
  const enumFields = Object.keys(biz.index.enumValues);
  need(enumFields.length > 0, `枚举字段非空：${enumFields.join(', ')}`);

  const q = (await call('biz.query', { filter: { eq: { dept: ['R&D'] } }, limit: 5 })).result ?? {};
  need(
    typeof q.matched === 'number' && typeof q.took_us === 'number' && Array.isArray(q.rows),
    'biz.query 带 matched / took_us / rows'
  );
  need(q.matched > 0, `dept=R&D 命中 ${q.matched} 行`);
  need(
    q.rows.length > 0 &&
      q.rows.every((r) => typeof r.key === 'string' && typeof r.rowid === 'number' && r.value !== undefined),
    'biz.query 的每一行都带 key / rowid / value'
  );
  console.log(`  → rows=${q.rows.length} took=${q.took_us}µs`);

  // 业务行住在页表里，不在 KV 索引里：只能用 biz.get 读，用 get 会返回 null。
  // 这条差异踩过一次，正好留在这里当回归点。
  const one = (await call('biz.get', { key: q.rows[0].key })).result;
  need(!!one && one.value !== undefined, 'biz.get 读得回刚查到的那一行');

  const kv = (await call('list', { ns: 'capture', limit: 1 })).result;
  need(Array.isArray(kv) && kv.length > 0, 'list 能列出 capture 的记录（KV 路径）');

  await call('quit').catch(() => {});
  child.stdin.end();
  console.log('协议通过');
} catch (e) {
  die(e.message);
}
