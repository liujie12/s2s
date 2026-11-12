/**
 * 写接口基线（PT-06：发布 / 收藏 / 举报）。
 *
 * 与 `perf_readonly_baseline.mjs` 的分工：本脚本会**真实写入**，因此：
 *   - 仅用白名单测试账号，token 只驻内存、不落盘；
 *   - 发布帖统一 `[测试]` 前缀，测完立即 `offline` 下架（正式环境无删除接口）；
 *   - 收藏成对执行（N 次收藏 + N 次取消），结束时回到未收藏；
 *   - 举报只发 1 条（账号日限 10 条），会把 report_id 记入结果供清理。
 *
 * 无既定 SLA：只记录客户端 TTFB 与错误率，作为后续回归基线。
 *
 * 用法：
 *   PERF_TEST_PHONE=<白名单测试号> node tool/perf_write_baseline.mjs
 *   PERF_WRITE_N=30 PERF_TEST_PHONE=... node tool/perf_write_baseline.mjs
 *   PERF_SKIP_CREATE=1 PERF_SKIP_REPORT=1 ...   # 只测收藏
 */

import { mkdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

/** 正式环境基址。 */
const BASE_URL = (process.env.PERF_BASE_URL || 'https://s2s.build110.com').replace(/\/+$/, '');

/** 测试手机号（生产白名单内），必填。 */
const TEST_PHONE = process.env.PERF_TEST_PHONE || '';

/** dev 桩验证码。 */
const TEST_CODE = process.env.PERF_TEST_CODE || '888888';

/** 收藏 / 取消收藏各自循环次数。 */
const N = Number(process.env.PERF_WRITE_N || 30);

/** 是否跳过发布与举报。 */
const SKIP_CREATE = process.env.PERF_SKIP_CREATE === '1';
const SKIP_REPORT = process.env.PERF_SKIP_REPORT === '1';

/** 发布用叶子类目（默认 10105「其他全职」，无资质要求；10101 餐饮需资质会回 40302）。 */
const LEAF_ID = Number(process.env.PERF_LEAF_ID || 10105);

/** 结果目录。 */
const OUT_DIR = process.env.PERF_OUT_DIR || path.resolve(process.cwd(), 'build', 'perf');

/** 登录后的 token（仅内存）。 */
let TOKEN = '';

/** 公共请求头：每次新交互 ID + 唯一幂等键。 */
function headers(extra = {}) {
  return {
    'X-Interaction-Id': randomUUID(),
    'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    'Idempotency-Key': randomUUID(),
    ...extra,
  };
}

/**
 * 发一次请求并计时。
 *
 * 功能：解析 JSON 信封，记录客户端 TTFB、HTTP 状态与业务码。
 * 参数：method/path/body/useToken。
 * 返回：`{ latencyMs, httpStatus, code, ok, data, error }`。
 */
async function send(method, urlPath, { body, useToken = false } = {}) {
  const started = performance.now();
  try {
    const resp = await fetch(BASE_URL + urlPath, {
      method,
      headers: headers({
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(useToken ? { Authorization: `Bearer ${TOKEN}` } : {}),
      }),
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10000),
    });
    const text = await resp.text();
    const latencyMs = performance.now() - started;
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      // 非 JSON 交给 httpStatus 判定。
    }
    return {
      latencyMs,
      httpStatus: resp.status,
      code: typeof parsed?.code === 'number' ? parsed.code : null,
      ok: resp.status === 200 && parsed?.code === 0,
      data: parsed?.data ?? null,
      error: null,
    };
  } catch (err) {
    return {
      latencyMs: performance.now() - started,
      httpStatus: 0,
      code: null,
      ok: false,
      data: null,
      error: err?.name === 'TimeoutError' ? 'timeout' : 'network',
    };
  }
}

/**
 * 登录换 token（dev 桩验证码；429 等 Retry-After 重发一次）。
 *
 * 功能：仅内存保存 token，不打印手机号与 token。
 * 参数：无。
 * 返回：无（写入 [TOKEN]）。
 */
async function login() {
  const sendOnce = () =>
    fetch(`${BASE_URL}/auth/sms/send`, {
      method: 'POST',
      headers: headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ phone: TEST_PHONE, scene: 'login' }),
    });
  let resp = await sendOnce();
  if (resp.status === 429) {
    const waitSec = Math.min(Number(resp.headers.get('Retry-After') || 60), 65);
    console.log(`验证码发送限频，等待 ${waitSec}s 后重试…`);
    await new Promise((r) => setTimeout(r, waitSec * 1000));
    resp = await sendOnce();
  }
  if (resp.status !== 200) throw new Error(`发送验证码失败：HTTP ${resp.status}`);

  const loginResp = await fetch(`${BASE_URL}/auth/sms/login`, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'application/json' }),
    body: JSON.stringify({ phone: TEST_PHONE, code: TEST_CODE, agreed: true, platform: 'android' }),
  });
  const body = await loginResp.json().catch(() => null);
  if (loginResp.status !== 200 || body?.code !== 0 || typeof body?.data?.token !== 'string') {
    throw new Error(`登录失败：HTTP ${loginResp.status} code=${body?.code}`);
  }
  TOKEN = body.data.token;
  console.log(`登录完成：user_id=${body?.data?.user?.id ?? '?'}（token 仅驻内存）`);
}

/**
 * 取一个在架帖子作为收藏/举报目标。
 *
 * 功能：走只读搜索接口，避免硬编码帖子 ID。
 * 返回：帖子 ID；找不到返回 0。
 */
async function pickPostId() {
  const tree = await (await fetch(`${BASE_URL}/categories/tree`, { headers: headers() })).json();
  const leaf = (function firstLeaf(nodes) {
    for (const n of nodes || []) {
      if (Array.isArray(n?.children) && n.children.length) {
        const nested = firstLeaf(n.children);
        if (nested) return nested;
      }
      if (Number.isInteger(n?.id)) return n.id;
    }
    return 0;
  })(tree?.data?.categories);
  const q = new URLSearchParams({
    category_ids: String(leaf),
    post_type: 'resource',
    radius: '5',
    grid_id: '26700_6728',
    category_version: String(tree?.data?.version || ''),
    lng: '120.15',
    lat: '30.28',
    page: '1',
    page_size: '1',
  });
  const list = await (await fetch(`${BASE_URL}/posts/search?${q}`, { headers: headers() })).json();
  const id = list?.data?.items?.[0]?.id;
  return Number.isInteger(id) ? id : 0;
}

/**
 * 汇总一组写请求。
 *
 * 功能：算成功数、错误分类与 P50/P95/P99。
 * 参数：samples 采样数组。
 * 返回：统计对象。
 */
function summarize(samples) {
  const ok = samples.filter((s) => s.ok);
  const lat = ok.map((s) => s.latencyMs).sort((a, b) => a - b);
  const pct = (p) => (lat.length ? Number(lat[Math.min(lat.length - 1, Math.ceil((p / 100) * lat.length) - 1)].toFixed(1)) : null);
  const failures = {};
  for (const s of samples) {
    if (s.ok) continue;
    const key = s.error || `http_${s.httpStatus}_code_${s.code}`;
    failures[key] = (failures[key] || 0) + 1;
  }
  return {
    total: samples.length,
    ok: ok.length,
    success_rate: samples.length ? Number(((ok.length / samples.length) * 100).toFixed(2)) : 0,
    p50_ms: pct(50),
    p95_ms: pct(95),
    p99_ms: pct(99),
    max_ms: lat.length ? Number(lat[lat.length - 1].toFixed(1)) : null,
    failures,
  };
}

/**
 * 主流程：登录 → 收藏往返 → 发布并下架 → 举报 → 落盘。
 *
 * 参数：无。
 * 返回：无（结果写文件并打印）。
 */
async function main() {
  if (!TEST_PHONE) throw new Error('缺少 PERF_TEST_PHONE，拒绝在正式环境做无账号写入');

  console.log(`写接口基线 | base=${BASE_URL} | 收藏往返 ${N} 次`);
  await login();

  const postId = await pickPostId();
  if (!postId) throw new Error('未取到在架帖子，无法做收藏/举报基线');
  console.log(`目标帖子：${postId}`);

  const report = {
    schema_version: 1,
    generated_at: new Date().toISOString(),
    base_url: BASE_URL,
    environment: 'prod',
    note: '客户端 TTFB 基线；写操作仅测试账号，帖子上 [测试] 前缀并下架，收藏往返归零',
    target_post_id: postId,
    runs: {},
  };

  // 1) 收藏 / 取消收藏
  const favSamples = [];
  for (let i = 0; i < N; i++) {
    favSamples.push(await send('POST', `/posts/${postId}/favorite`, { useToken: true }));
  }
  const unfavSamples = [];
  for (let i = 0; i < N; i++) {
    unfavSamples.push(await send('DELETE', `/posts/${postId}/favorite`, { useToken: true }));
  }
  report.runs.favorite = summarize(favSamples);
  report.runs.unfavorite = summarize(unfavSamples);
  console.log(`收藏：${JSON.stringify(report.runs.favorite)}`);
  console.log(`取消：${JSON.stringify(report.runs.unfavorite)}`);

  // 2) 发布 1 条 [测试] 帖并下架
  if (!SKIP_CREATE) {
    const create = await send('POST', '/posts', {
      useToken: true,
      body: {
        type: 'resource',
        leaf_category_id: LEAF_ID,
        title: `[测试] PT-06 写基线 ${Date.now()}`,
        description: '自动化写接口基线测试数据，测完立即下架',
        price: 100,
        lng: 120.15,
        lat: 30.28,
        address: '安徽省合肥市',
      },
    });
    report.runs.create_post = summarize([create]);
    const createdId = create?.data?.id;
    report.created_post = { id: createdId ?? null, ok: create.ok };

    if (create.ok && createdId) {
      const detail = await send('GET', `/posts/${createdId}`, { useToken: true });
      const version = detail?.data?.version ?? create?.data?.version;
      if (Number.isInteger(version)) {
        const offline = await send('PATCH', `/posts/${createdId}/status`, {
          useToken: true,
          body: { action: 'offline', version },
        });
        report.runs.offline_post = summarize([offline]);
        report.created_post.offline_ok = offline.ok;
      } else {
        report.created_post.offline_ok = false;
        report.created_post.offline_error = '未取到 version';
      }
    }
    console.log(`发布：${JSON.stringify(report.runs.create_post)}；下架：${JSON.stringify(report.runs.offline_post)}`);
  }

  // 3) 举报 1 条（账号日限 10，重复同因去重）
  if (!SKIP_REPORT) {
    const rep = await send('POST', `/posts/${postId}/report`, {
      useToken: true,
      body: { reason: 'other', remark: '[测试] PT-06 写接口基线' },
    });
    report.runs.report = summarize([rep]);
    report.report_created = { report_id: rep?.data?.report_id ?? null, ok: rep.ok };
    console.log(`举报：${JSON.stringify(report.runs.report)} report_id=${report.report_created.report_id}`);
  }

  await mkdir(OUT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outFile = path.join(OUT_DIR, `write-baseline-${stamp}.json`);
  await writeFile(outFile, JSON.stringify(report, null, 2), 'utf8');
  console.log(`\n结果已写入：${outFile}`);
}

main().catch((err) => {
  console.error('写基线执行失败：', err?.message || err);
  process.exitCode = 1;
});
