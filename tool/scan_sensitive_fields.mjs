/**
 * A-16 响应敏感字段全量扫描（只读）。
 *
 * 做法：从 `docs/api/openapi.yaml` 解析出所有「公开 GET」（operation 下 `security: []`），
 * 用测试值替换路径参数后逐个请求，对响应体与响应头扫：
 *   1. 未脱敏手机号（1[3-9] + 9 位，前后不接数字）
 *   2. 18 位身份证号
 *   3. Authorization / token / JWT 回显
 *   4. 联系方式字段（phone / mobile / wechat / qq / contact_*）
 *   5. Set-Cookie
 *
 * 只发 GET，不写入、不带测试账号凭据；鉴权端点（security 非空）不在本轮范围。
 *
 * 用法：node tool/scan_sensitive_fields.mjs
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

/** 正式环境基址。 */
const BASE_URL = (process.env.SCAN_BASE_URL || 'https://s2s.build110.com').replace(/\/+$/, '');

/** openapi 契约路径。 */
const OPENAPI_PATH = path.resolve(process.cwd(), 'docs', 'api', 'openapi.yaml');

/** 结果目录。 */
const OUT_DIR = path.resolve(process.cwd(), 'build', 'security');

/** 路径参数替换表：无法安全构造的参数先给测试值。 */
const PATH_PARAM_VALUES = {
  post_id: '9001',
  postId: '9001',
  user_id: '9504',
  userId: '9504',
  category_id: '10101',
  categoryId: '10101',
  grid_id: '26700_6728',
  gridId: '26700_6728',
  conversation_id: '1',
  conversationId: '1',
  notification_id: '1',
  notificationId: '1',
  report_id: '1',
  reportId: '1',
  version: '1.0.0',
  id: '9001',
};

/** 敏感模式：命中即视为疑似泄露。 */
const PATTERNS = [
  { key: 'unmasked_phone', re: /(?<!\d)1[3-9]\d{9}(?!\d)/g, note: '未脱敏大陆手机号' },
  { key: 'id_card', re: /(?<!\d)\d{17}[\dXx](?!\d)/g, note: '18 位身份证号' },
  { key: 'jwt', re: /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g, note: 'JWT 串回显' },
  { key: 'authorization_echo', re: /["']?authorization["']?\s*[:=]\s*["'][^"']+["']/gi, note: 'Authorization 回显' },
  { key: 'token_echo', re: /["']?(?:access_token|refresh_token|token)["']?\s*:\s*["'][A-Za-z0-9._-]{20,}["']/gi, note: 'token 字段回显' },
  { key: 'contact_field', re: /["'](?:contact_phone|contact_wechat|contact_qq|wechat|qq|mobile)["']\s*:/gi, note: '联系方式字段' },
];

/**
 * 从 openapi 抽取公开 GET 端点。
 *
 * 功能：按缩进解析 paths 段，记录每个 operation 是否声明 `security: []`。
 * 返回：`[{ raw, method, path, publicOperation }]`。
 */
function extractPublicGets(yamlText) {
  const lines = yamlText.split(/\r?\n/);
  const ops = [];
  let curPath = null;
  let curOp = null;
  const flush = () => {
    if (curPath && curOp) ops.push({ path: curPath, method: curOp.method, securityEmpty: curOp.securityEmpty === true });
    curOp = null;
  };
  for (const line of lines) {
    const pathMatch = /^ {2}(\/[^\s:]+):\s*$/.exec(line);
    if (pathMatch) {
      flush();
      curPath = pathMatch[1];
      continue;
    }
    const opMatch = /^ {4}(get|post|put|patch|delete):\s*$/.exec(line);
    if (opMatch && curPath) {
      flush();
      curOp = { method: opMatch[1].toUpperCase(), hasSecurity: false };
      continue;
    }
    if (curOp && /^ {6}security:\s*\[\]\s*$/.test(line)) {
      curOp.securityEmpty = true;
    }
  }
  flush();
  return ops.filter((o) => o.method === 'GET').map((o) => ({
    ...o,
    // 契约里公开端点显式声明 `security: []`；未声明者继承全局鉴权。
    publicOperation: o.securityEmpty === true,
  }));
}

/**
 * 把契约路径转成可请求 URL。
 *
 * 功能：替换 `{param}`；替换不了的参数返回 null。
 * 返回：URL 字符串或 null。
 */
function materialize(rawPath) {
  let ok = true;
  const filled = rawPath.replace(/\{([^}]+)\}/g, (_, name) => {
    const v = PATH_PARAM_VALUES[name];
    if (v === undefined) {
      ok = false;
      return '';
    }
    return v;
  });
  return ok ? filled : null;
}

/**
 * 扫描一段文本中的敏感模式。
 *
 * 功能：逐模式收集命中片段（最多 3 条，避免报告爆炸）。
 * 参数：text 待扫文本。
 * 返回：命中数组 `[{ key, note, samples }]`。
 */
function scanText(text) {
  const hits = [];
  for (const p of PATTERNS) {
    const found = [...text.matchAll(p.re)].map((m) => m[0].slice(0, 80));
    if (found.length) {
      hits.push({ key: p.key, note: p.note, count: found.length, samples: [...new Set(found)].slice(0, 3) });
    }
  }
  return hits;
}

/**
 * 请求单个端点并扫描。
 *
 * 功能：记录 HTTP 状态、业务码、耗时，扫响应头与响应体。
 * 返回：单端点结果对象。
 */
async function scanEndpoint(urlPath) {
  const started = performance.now();
  try {
    const resp = await fetch(BASE_URL + urlPath, {
      method: 'GET',
      headers: { 'X-Interaction-Id': randomUUID(), 'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301' },
      signal: AbortSignal.timeout(10000),
    });
    const text = await resp.text();
    const latencyMs = Number((performance.now() - started).toFixed(1));
    let code = null;
    try {
      code = JSON.parse(text)?.code ?? null;
    } catch {
      // 非 JSON 不阻塞扫描。
    }
    const headerHits = [];
    const setCookie = resp.headers.get('set-cookie');
    if (setCookie) headerHits.push({ key: 'set_cookie', note: '响应设置 Cookie', samples: [setCookie.slice(0, 80)] });
    const authHeader = resp.headers.get('authorization');
    if (authHeader) headerHits.push({ key: 'authorization_header', note: '响应回显 Authorization 头', samples: [authHeader.slice(0, 40)] });

    return {
      path: urlPath,
      httpStatus: resp.status,
      code,
      latencyMs,
      bodyBytes: Buffer.byteLength(text),
      headerHits,
      bodyHits: scanText(text),
    };
  } catch (err) {
    return {
      path: urlPath,
      httpStatus: 0,
      code: null,
      latencyMs: Number((performance.now() - started).toFixed(1)),
      error: err?.name === 'TimeoutError' ? 'timeout' : 'network',
      headerHits: [],
      bodyHits: [],
    };
  }
}

/**
 * 主流程：解析契约 → 逐个扫描 → 落盘摘要。
 *
 * 参数：无。
 * 返回：无（结果写文件并打印）。
 */
async function main() {
  const yamlText = await readFile(OPENAPI_PATH, 'utf8');
  const allGets = extractPublicGets(yamlText);
  const publicGets = allGets.filter((o) => o.publicOperation);
  const skippedAuth = allGets.length - publicGets.length;

  const targets = [];
  const unmaterialized = [];
  for (const op of publicGets) {
    const url = materialize(op.path);
    if (url) targets.push(url);
    else unmaterialized.push(op.path);
  }

  console.log(`公开 GET ${targets.length} 个（跳过鉴权 ${skippedAuth} 个、参数不可构造 ${unmaterialized.length} 个）`);

  // 契约未声明 security: []、但实际匿名可用的端点（首轮实测 40001 而非 40101），补充覆盖。
  const tree = await fetch(`${BASE_URL}/categories/tree`, {
    headers: { 'X-Interaction-Id': randomUUID(), 'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301' },
  })
    .then((r) => r.json())
    .catch(() => null);
  const catVersion = encodeURIComponent(tree?.data?.version ?? '');
  // 10101 是种子/演示数据所在类目，10105 用于覆盖空结果分支；两类都扫，避免「响应为空 = 无泄露」的假绿。
  const extraTargets = [];
  for (const cat of [10101, 10105]) {
    const common = `grid_id=26700_6728&radius=5&lng=120.15&lat=30.28&category_ids=${cat}&category_version=${catVersion}&post_type=resource`;
    extraTargets.push(`/map/pins?${common}&zoom=14.5`);
    extraTargets.push(`/posts/search?${common}&page=1&page_size=50`);
  }
  extraTargets.push(
    `/posts/search?grid_id=26700_6728&radius=5&lng=120.15&lat=30.28&category_ids=10101&category_version=${catVersion}&post_type=resource&keyword=${encodeURIComponent('测试')}&page=1&page_size=50`,
  );
  targets.push(...extraTargets);

  const results = [];
  for (const url of targets) {
    results.push(await scanEndpoint(url));
  }

  const flagged = results.filter((r) => r.headerHits.length || r.bodyHits.length);
  const summary = {
    schema_version: 1,
    generated_at: new Date().toISOString(),
    base_url: BASE_URL,
    scope: 'openapi 中 security 为空的 GET 端点；不含鉴权端点与写接口',
    counts: {
      public_gets: publicGets.length,
      scanned: results.length,
      skipped_auth: skippedAuth,
      unmaterialized: unmaterialized.length,
      flagged: flagged.length,
    },
    unmaterialized_paths: unmaterialized,
    contract_gap: [
      '/posts/search 与 /map/pins 实际匿名可访问（无 token 返回 40001 参数错，而非 40101），但契约未声明 security: []',
      '/legal/documents 返回 404，契约存在该路径而线上未开放',
    ],
    extra_targets: extraTargets,
    flagged,
    results,
  };

  await mkdir(OUT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outFile = path.join(OUT_DIR, `sensitive-scan-${stamp}.json`);
  await writeFile(outFile, JSON.stringify(summary, null, 2), 'utf8');

  for (const r of results) {
    const mark = r.headerHits.length || r.bodyHits.length ? 'HIT ' : 'ok  ';
    console.log(`${mark}${String(r.httpStatus).padEnd(4)} code=${String(r.code).padEnd(6)} ${String(r.latencyMs).padStart(7)}ms ${r.path}`);
    for (const h of [...r.headerHits, ...r.bodyHits]) {
      console.log(`      - ${h.key}: ${h.samples.join(' | ')}`);
    }
  }
  console.log(`\n命中端点 ${flagged.length} / 扫描 ${results.length}；结果：${outFile}`);
}

main().catch((err) => {
  console.error('扫描失败：', err?.message || err);
  process.exitCode = 1;
});
