/**
 * 只读接口低并发基线（T1-05 / A-19 / PT-01~PT-05）。
 *
 * 背景：正式环境不重启、无容器底座，k6 未安装；本脚本只用 Node 内置 fetch
 * 做 1~3 并发 × 固定时长的只读采样，产出可归档的 JSON 与终端汇总。
 *
 * 口径警告：本脚本只能测到**客户端观测到的 TTFB**。PT-01~PT-05 的判据是
 * 服务端访问日志里的 `rt_ms`（编码规范 §7），二者不可互相顶替；因此本基线
 * 用于「错误率 + 客户端时延参考」，正式 P95 判定仍需运维提供 rt_ms 日志。
 *
 * 用法：
 *   node tool/perf_readonly_baseline.mjs
 *   PERF_CONCURRENCY=1,2,3 PERF_DURATION_SEC=60 node tool/perf_readonly_baseline.mjs
 *   PERF_TOKEN=<token> PERF_CONVERSATION_ID=16 node tool/perf_readonly_baseline.mjs
 *
 * 只读保证：仅发 GET；不携带手机号、不写业务数据、不落 token 到输出文件。
 */

import { mkdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

/** 正式环境基址（可用 PERF_BASE_URL 覆盖）。 */
const BASE_URL = (process.env.PERF_BASE_URL || 'https://s2s.build110.com').replace(/\/+$/, '');

/** 并发档位，缺省 1/2/3，与批准口径「1–3 并发」一致。 */
const CONCURRENCY_LEVELS = (process.env.PERF_CONCURRENCY || '1,2,3')
  .split(',')
  .map((v) => Number(v.trim()))
  .filter((v) => Number.isInteger(v) && v > 0);

/** 每档并发持续秒数，缺省 60 秒。 */
const DURATION_SEC = Number(process.env.PERF_DURATION_SEC || 60);

/** 单请求超时（毫秒）；避免弱网挂死采样循环。 */
const REQUEST_TIMEOUT_MS = Number(process.env.PERF_REQUEST_TIMEOUT_MS || 10000);

/** 结果输出目录。 */
const OUT_DIR = process.env.PERF_OUT_DIR || path.resolve(process.cwd(), 'build', 'perf');

/** 登录态只读端点所需 token（仅 PT-05；未注入时可由测试号登录换取）。 */
let TOKEN = process.env.PERF_TOKEN || '';

/** 会话 ID（仅 PT-05；已知 ID 时 90 天隐藏也可读历史，见契约 listMessages）。 */
const CONVERSATION_ID = process.env.PERF_CONVERSATION_ID || '';

/** 可选：未注入 PERF_TOKEN 时，用白名单测试号走 dev 桩验证码登录换 token（仅在内存中，不落盘）。 */
const TEST_PHONE = process.env.PERF_TEST_PHONE || '';

/** 可选：测试验证码，缺省沿用 dev 桩值。 */
const TEST_CODE = process.env.PERF_TEST_CODE || '888888';

/** 只跑指定端点（逗号分隔，如 `PT-01,PT-02`）；为空表示全跑。 */
const ONLY = (process.env.PERF_ONLY || '')
  .split(',')
  .map((v) => v.trim())
  .filter(Boolean);

/**
 * 构造每次请求都要新生成的交互头。
 *
 * 功能：契约要求 `X-Interaction-Id` 唯一，采样时逐请求生成，避免服务端按交互去重。
 * 参数：无。
 * 返回：请求头对象（含设备 ID 与交互 ID）。
 */
function freshHeaders() {
  return {
    'X-Interaction-Id': randomUUID(),
    'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
  };
}

/**
 * 发起一次 GET 并解析 JSON 信封。
 *
 * 功能：记录客户端耗时（含网络与序列化）、HTTP 状态与业务码；异常归类为 network。
 * 参数：endpoint 端点描述对象（path/query/needsAuth）。
 * 返回：`{ latencyMs, httpStatus, code, ok, error }`。
 */
async function callOnce(endpoint) {
  const url = new URL(BASE_URL + endpoint.path);
  for (const [k, v] of Object.entries(endpoint.query || {})) {
    url.searchParams.set(k, String(v));
  }
  const headers = freshHeaders();
  if (endpoint.needsAuth) headers.Authorization = `Bearer ${TOKEN}`;

  const started = performance.now();
  try {
    const resp = await fetch(url, {
      method: 'GET',
      headers,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    const text = await resp.text();
    const latencyMs = performance.now() - started;
    let code = null;
    try {
      const body = JSON.parse(text);
      code = typeof body?.code === 'number' ? body.code : null;
    } catch {
      // 非 JSON 由 httpStatus 判定失败，不抛错以免中断采样。
    }
    return {
      latencyMs,
      httpStatus: resp.status,
      code,
      ok: resp.status === 200 && code === 0,
      error: null,
    };
  } catch (err) {
    return {
      latencyMs: performance.now() - started,
      httpStatus: 0,
      code: null,
      ok: false,
      error: err?.name === 'TimeoutError' ? 'timeout' : 'network',
    };
  }
}

/**
 * 计算单个并发档位的统计量。
 *
 * 功能：过滤失败样本后算分位；错误按 network/timeout/http/业务码分类计数。
 * 参数：samples 采样数组；elapsedSec 实际采样秒数。
 * 返回：统计对象（含成功率与各分位毫秒）。
 */
function summarize(samples, elapsedSec) {
  const total = samples.length;
  const okSamples = samples.filter((s) => s.ok);
  const latencies = okSamples.map((s) => s.latencyMs).sort((a, b) => a - b);

  /** 取排序数组的 p 分位值（最近秩法）。 */
  const pct = (p) => {
    if (latencies.length === 0) return null;
    const idx = Math.min(latencies.length - 1, Math.ceil((p / 100) * latencies.length) - 1);
    return Number(latencies[Math.max(0, idx)].toFixed(1));
  };

  const failures = {};
  for (const s of samples) {
    if (s.ok) continue;
    const key = s.error ? s.error : `http_${s.httpStatus}_code_${s.code}`;
    failures[key] = (failures[key] || 0) + 1;
  }

  return {
    total,
    ok: okSamples.length,
    success_rate: total === 0 ? 0 : Number(((okSamples.length / total) * 100).toFixed(2)),
    rps: elapsedSec === 0 ? 0 : Number((total / elapsedSec).toFixed(2)),
    latency_ms: {
      min: latencies.length ? Number(latencies[0].toFixed(1)) : null,
      avg: latencies.length
        ? Number((latencies.reduce((a, b) => a + b, 0) / latencies.length).toFixed(1))
        : null,
      p50: pct(50),
      p95: pct(95),
      p99: pct(99),
      max: latencies.length ? Number(latencies[latencies.length - 1].toFixed(1)) : null,
    },
    failures,
    http_status_dist: samples.reduce((acc, s) => {
      acc[s.httpStatus] = (acc[s.httpStatus] || 0) + 1;
      return acc;
    }, {}),
  };
}

/**
 * 在指定并发下跑固定时长。
 *
 * 功能：起 N 个 worker 各自串行请求，到点停止；中途每 15 秒打印一次心跳，
 *       便于长任务观察是否卡死。
 * 参数：endpoint 端点；concurrency 并发数；durationSec 持续秒数。
 * 返回：统计对象（附带 samples 供落盘）。
 */
async function runLevel(endpoint, concurrency, durationSec) {
  const samples = [];
  const deadline = Date.now() + durationSec * 1000;
  const startedAt = Date.now();

  const worker = async () => {
    while (Date.now() < deadline) {
      samples.push(await callOnce(endpoint));
    }
  };

  const heartbeat = setInterval(() => {
    const elapsed = ((Date.now() - startedAt) / 1000).toFixed(0);
    console.log(`    … ${endpoint.id} c=${concurrency} ${elapsed}s/${durationSec}s, n=${samples.length}`);
  }, 15000);

  await Promise.all(Array.from({ length: concurrency }, worker));
  clearInterval(heartbeat);

  const elapsedSec = (Date.now() - startedAt) / 1000;
  return summarize(samples, elapsedSec);
}

/**
 * 取分类树里的第一个叶子类目与版本号。
 *
 * 功能：作为 /map/pins 与 /posts/search 的合法查询参数，避免用硬编码类目。
 * 参数：无。
 * 返回：`{ version, leafCategoryId }`。
 */
async function bootstrapCategory() {
  const resp = await fetch(`${BASE_URL}/categories/tree`, { headers: freshHeaders() });
  const body = await resp.json();
  if (body?.code !== 0) throw new Error(`分类树返回异常：HTTP ${resp.status} code=${body?.code}`);

  /** 递归寻找第一个无 children 的节点。 */
  const firstLeaf = (nodes) => {
    for (const node of nodes || []) {
      if (Array.isArray(node?.children) && node.children.length > 0) {
        const nested = firstLeaf(node.children);
        if (nested) return nested;
      }
      if (Number.isInteger(node?.id)) return node.id;
    }
    return 0;
  };

  const leaf = firstLeaf(body?.data?.categories);
  if (!leaf) throw new Error('分类树中未找到叶子类目');
  return { version: body?.data?.version, leafCategoryId: leaf };
}

/**
 * 取一个在架帖子 ID 作为 PT-04 样本。
 *
 * 功能：详情端点需要一个真实 post_id；列表为空时返回 0（该端点跳过）。
 * 参数：query 与 /posts/search 相同的筛选条件。
 * 返回：帖子 ID 或 0。
 */
async function bootstrapPostId(query) {
  const url = new URL(BASE_URL + '/posts/search');
  for (const [k, v] of Object.entries(query)) url.searchParams.set(k, String(v));
  const resp = await fetch(url, { headers: freshHeaders() });
  const body = await resp.json();
  const item = body?.data?.items?.[0];
  return Number.isInteger(item?.id) ? item.id : 0;
}

/**
 * 用白名单测试号走 dev 桩验证码登录换取 token。
 *
 * 功能：仅当 PT-05 需要登录态且未注入 PERF_TOKEN 时调用；token 只留在内存，
 *       不打印、不落盘。登录只写设备行，不写业务数据。
 * 参数：phone 生产白名单内测试号。
 * 返回：token 字符串。
 */
async function loginForToken(phone) {
  /**
   * 发送验证码；命中 1 分钟轨会 429，按 Retry-After 等一次再发。
   * 注意：验证码一次性消费，不能拿旧码重试（会 40001）。
   */
  const sendOnce = () =>
    fetch(`${BASE_URL}/auth/sms/send`, {
      method: 'POST',
      headers: { ...freshHeaders(), 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() },
      body: JSON.stringify({ phone, scene: 'login' }),
    });

  let sendResp = await sendOnce();
  if (sendResp.status === 429) {
    const waitSec = Math.min(Number(sendResp.headers.get('Retry-After') || 60), 65);
    console.log(`发送验证码被限频，等待 ${waitSec}s 后重试一次…`);
    await new Promise((resolve) => setTimeout(resolve, waitSec * 1000));
    sendResp = await sendOnce();
  }
  if (sendResp.status !== 200) {
    throw new Error(`发送验证码失败：HTTP ${sendResp.status}`);
  }

  const loginResp = await fetch(`${BASE_URL}/auth/sms/login`, {
    method: 'POST',
    headers: { ...freshHeaders(), 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() },
    body: JSON.stringify({ phone, code: TEST_CODE, agreed: true, platform: 'android' }),
  });
  const body = await loginResp.json().catch(() => null);
  if (loginResp.status !== 200 || body?.code !== 0 || typeof body?.data?.token !== 'string') {
    throw new Error(`登录失败：HTTP ${loginResp.status} code=${body?.code}`);
  }
  console.log(`登录完成：user_id=${body?.data?.user?.id ?? '?'}（token 仅驻内存，不落盘）`);
  return body.data.token;
}

/**
 * 主流程：引导取样 → 逐端点逐并发采样 → 落盘 → 打印汇总。
 *
 * 功能：串行执行以保证「逐接口单独出数」，不与其它端点混在同一时间窗。
 * 参数：无。
 * 返回：无（结果写文件并打印）。
 */
async function main() {
  console.log(`只读低并发基线 | base=${BASE_URL} | 并发=${CONCURRENCY_LEVELS.join('/')} | 每档=${DURATION_SEC}s`);

  const { version, leafCategoryId } = await bootstrapCategory();
  const commonQuery = {
    category_ids: String(leafCategoryId),
    post_type: 'resource',
    radius: '5',
    grid_id: '26700_6728',
    category_version: version,
    lng: '120.15',
    lat: '30.28',
  };
  const postId = await bootstrapPostId({ ...commonQuery, page: '1', page_size: '20' });
  console.log(`引导完成：leaf=${leafCategoryId} version=${version} postId=${postId || 'N/A'}`);

  // 登录态端点：未注入 token 且给了测试号时，内存内登录换取（不落盘）。
  const wantsPt05 = !ONLY.length || ONLY.includes('PT-05');
  const wantsAuth = !ONLY.length || wantsPt05 || ONLY.includes('PT-04');
  if (!TOKEN && TEST_PHONE && wantsAuth) {
    try {
      TOKEN = await loginForToken(TEST_PHONE);
    } catch (err) {
      console.log(`登录换 token 失败：${err?.message || err}`);
      throw new Error('登录态端点需要 token，登录未成功，已中止（不降级为匿名口径）');
    }
  }

  const endpoints = [
    {
      id: 'PT-03',
      name: 'GET /categories/tree',
      path: '/categories/tree',
      query: {},
      needsAuth: false,
    },
    {
      id: 'PT-01',
      name: 'GET /map/pins',
      path: '/map/pins',
      query: { ...commonQuery, zoom: '14.5' },
      needsAuth: false,
    },
    {
      id: 'PT-02',
      name: 'GET /posts/search',
      path: '/posts/search',
      query: { ...commonQuery, page: '1', page_size: '20' },
      needsAuth: false,
    },
    {
      id: 'PT-04',
      name: 'GET /posts/{post_id}',
      path: postId ? `/posts/${postId}` : '',
      query: {},
      needsAuth: Boolean(TOKEN),
      skipReason: postId ? null : '正式环境当前分类无在架帖子，无 post_id 可采样',
    },
    {
      id: 'PT-05',
      name: 'GET /conversations/{id}/messages',
      path: CONVERSATION_ID ? `/conversations/${CONVERSATION_ID}/messages` : '',
      query: { page_size: '30' },
      needsAuth: true,
      skipReason: !TOKEN || !CONVERSATION_ID ? '未注入 PERF_TOKEN / PERF_CONVERSATION_ID，登录态端点跳过' : null,
    },
  ];

  const selected = ONLY.length ? endpoints.filter((e) => ONLY.includes(e.id)) : endpoints;
  const report = {
    schema_version: 1,
    generated_at: new Date().toISOString(),
    base_url: BASE_URL,
    environment: 'prod',
    readonly: true,
    concurrency_levels: CONCURRENCY_LEVELS,
    duration_sec_per_level: DURATION_SEC,
    measurement_note:
      'latency_ms 为客户端 TTFB（含网络），不是服务端访问日志的 rt_ms；PT-01~PT-05 的 P95 判定仍以服务端 rt_ms 为准。',
    bootstrap: { leaf_category_id: leafCategoryId, category_version: version, post_id: postId || null },
    runs: [],
    skipped: [],
  };

  for (const endpoint of selected) {
    if (endpoint.skipReason || !endpoint.path) {
      report.skipped.push({ id: endpoint.id, endpoint: endpoint.name, reason: endpoint.skipReason });
      console.log(`跳过 ${endpoint.id} ${endpoint.name}：${endpoint.skipReason}`);
      continue;
    }
    for (const concurrency of CONCURRENCY_LEVELS) {
      console.log(`  ▶ ${endpoint.id} ${endpoint.name} | c=${concurrency} | ${DURATION_SEC}s`);
      const stats = await runLevel(endpoint, concurrency, DURATION_SEC);
      report.runs.push({ id: endpoint.id, endpoint: endpoint.name, concurrency, ...stats });
      console.log(
        `    ✓ n=${stats.total} ok=${stats.ok}(${stats.success_rate}%) rps=${stats.rps} ` +
          `p50=${stats.latency_ms.p50}ms p95=${stats.latency_ms.p95}ms p99=${stats.latency_ms.p99}ms max=${stats.latency_ms.max}ms`,
      );
    }
  }

  await mkdir(OUT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outFile = path.join(OUT_DIR, `readonly-baseline-${stamp}.json`);
  await writeFile(outFile, JSON.stringify(report, null, 2), 'utf8');
  console.log(`\n结果已写入：${outFile}`);

  console.log('\n=== 汇总（客户端 TTFB，非服务端 rt_ms） ===');
  console.log('endpoint\tc\tn\tsuccess%\tp50\tp95\tp99\trps');
  for (const r of report.runs) {
    console.log(
      `${r.id}\t${r.concurrency}\t${r.total}\t${r.success_rate}\t${r.latency_ms.p50}\t${r.latency_ms.p95}\t${r.latency_ms.p99}\t${r.rps}`,
    );
  }
  if (report.skipped.length) {
    console.log('\n跳过项：');
    for (const s of report.skipped) console.log(`- ${s.id} ${s.endpoint}: ${s.reason}`);
  }
}

main().catch((err) => {
  console.error('基线执行失败：', err?.message || err);
  process.exitCode = 1;
});
