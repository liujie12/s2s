-- =============================================================================
-- 主看板 SQL 清单（Q1–Q7）
-- =============================================================================
-- 交付物归属：《可观测性架构方案》§9.1.1（「这七条 SQL 本身是 Batch1 交付物，
--             须落在 docs/ 或 scripts/ 下的【单一文件】内」）。
-- 消费方    ：定时任务 #8「可观测性阈值巡检」的 **T3** 判据 —— 逐条执行本文件
--             中【可执行】的 SQL 并计时，任一条单次执行 > `NfrObs.MIGRATION_DASHBOARD_SQL_SECONDS`
--             （= 10s，见 `src/main/java/com/s2s/server/common/constants/NfrObs.java`）
--             即命中阈值、写告警日志。
-- 写法纪律  ：每条查询前注明「编号 / 用途 / 对应看板项 / 口径要点 / 引用的常量名」；
--             每条后附 `-- EXPLAIN:` 占位行（真实 EXPLAIN 须在月表有数据后实测填入，
--             **本文件不预填任何 EXPLAIN 结果**）。
-- 月表说明  ：埋点按 `ts`（客户端采集时刻）归入月表 `track_event_YYYYMM`
--             （如 `track_event_202610`），执行前须把表名换成**当月**月表。
--             月表真实列（`V1__init_track_schema.sql`）：
--               event_name, interaction_id, user_id, device_id, ts, props(JSON),
--               leaf_category_id, completeness_level, is_ai_assisted, grid_id, created_at
--             事件专属字段一律在 `props` JSON 里（见可观测 §4.1.1），用 JSON 函数取值。
-- =============================================================================
--
-- ⚠️ 七条的可执行性（2026-10-10 首次交付 + 同日缺口裁定后更新）
--    —— 裁定依据见 说明文档 §2.9「2026-10-10 逐条裁定批次」的 DEC-18 行
--
--   编号 | 看板项                   | 状态            | 说明
--   -----|-------------------------|-----------------|--------------------------------
--   Q1   | §6.1 轴① 首次联系触发率  | **Batch2 交付物** | 依赖 `post_published` / `contact_event`
--        |                         |                 | 的属性清单（openapi 标「Batch2 补充」），
--        |                         |                 | 且轴①「Batch2 上线后可测」（§6.1）。
--        |                         |                 | **Batch1 从 T3 判定对象移出，记 N/A。**
--   Q2   | §6.1 轴② 图层切换成功率  | **可执行（两段式）** | 见 Q2 的两段式注入说明：主体在本库，
--        |                         |                 | 排除条件「重启窗口」由巡检侧先取窗口再注入
--   Q3   | §6.1 轴③ 完整发布率      | 可执行          | 直接读 `completeness_level` 列
--   Q4   | §6.2 轴① 两项反向哨兵    | **Batch2 交付物** | 同 Q1：依赖 Batch2 属性清单，且需
--        |                         |                 | 跨库 `report` 表。**Batch1 移出 T3，记 N/A。**
--   Q5   | §6.3 图层切换 P95 耗时   | 可执行          | 工程 SLA，与轴② 分开；读 `props` JSON
--   Q6   | §4.2 四段和校验不过      | 可执行          | 纯 `props` JSON 计算，无跨库
--   Q7   | §4.6 dropped_count 汇总   | **非 SQL 判据**  | 裁定改为**日志扫描判据**（不落月表、
--        |                         |                 | 不落表）—— **不在本文件内**，见文件末 Q7 说明
--
--   ⇒ T3 判定对象 = **Q2 / Q3 / Q5 / Q6 四条**；Q1 / Q4 记 **N/A（Batch2 交付物）**、
--     Q7 记 **N/A（非 SQL 判据）**。三种「不参与」必须区分，**不得一律记 SKIP**
--     （「扫描面为空是 SKIP 不是 PASS」的同源纪律：状态要如实、可区分）。
-- =============================================================================


-- =============================================================================
-- Q1 · 轴① 首次联系触发率 —— **Batch2 交付物（Batch1 不参与 T3，记 N/A）**
-- 看板项：§6.1 轴①；口径：PRD:2902「发布后 30 分钟内获得 ≥1 次联系点击的发布占比」
-- -----------------------------------------------------------------------------
-- 为何 Batch1 交付不了（2026-10-10 用户裁定：标为 Batch2 交付物）：
--   本查询需要「发布」与「联系」两侧都带 `post_id`，而 `track_event_YYYYMM`
--   **没有 `post_id` 列**（公共列只有 event_name / interaction_id / user_id /
--   device_id / ts；维度快照只有 leaf_category_id / completeness_level /
--   is_ai_assisted / grid_id）。`post_published` 与 `contact_event` 的
--   `post_id` / `elapsed_min` / `channel_type` 只能落在 `props` JSON，而
--   `docs/api/openapi.yaml` 把这两个事件的属性标注为「**Batch2 补充**」。
--   §6.1 亦明写轴① 为「Batch2 上线后可测」，§0.2.1（D1 兜底）规定 Batch1 为
--   冷启动观察期、**不作为 KPI 考核**。
--   ⇒ 故不写半成品 SQL（避免给 T3 一个会报错的判定对象）；待 Batch2 的属性清单
--     定稿后在本处补写，形如：
--       SELECT ... FROM track_event_YYYYMM p JOIN track_event_YYYYMM c
--         ON JSON_UNQUOTE(p.props->>'$.post_id') = JSON_UNQUOTE(c.props->>'$.post_id')
--        WHERE p.event_name='post_published' AND c.event_name='contact_event'
--          AND TIMESTAMPDIFF(SECOND, p.ts, c.ts) BETWEEN 0 AND 1800 ...
-- EXPLAIN:（Batch2 属性清单定稿、月表有数据后实测填入）


-- =============================================================================
-- Q2 · 轴② 分类图层加载成功率（含分子/分母口径与全部排除条件）
-- 看板项：§6.1 轴②（口径明细见 §6.1.1）
-- 常量  ：`NfrPerf.layerSwitchP95Ms` = 300（分子判据线，单次布尔口径）；
--         `NfrObs.RESTART_WARMUP_MINUTES` = 5（重启窗口预热，见 §4.2.2）
-- 口径  ：分子 = `result='success' AND duration_ms <= 300`；
--         分母 = 排除四类后的 `layer_switch` 会话数 —— ① `fail_reason='cancelled'`；
--         ② `network_type IN ('3g','2g','none')`（`unknown` **不在**排除集）；
--         ③ 四段和校验不过（表达式与 Q6 同一判据）；④ 落在 `restart_window` 内。
--
-- ★ 两段式（2026-10-10 用户裁定）—— 排除条件 ④ 由巡检侧注入，**不跨库 join**：
--   `restart_window` 表在**业务库**（`V2__restart_window.sql`），而埋点月表的设计
--   目标是「分析无需跨库 join」。故本查询在需要排除窗口的位置留占位：
--       /* RESTART_WINDOWS_EXCLUSION */
--   巡检任务执行本查询前：
--     (1) 先从**业务库**取窗口：SELECT start_at, end_at FROM restart_window;
--     (2) 把占位替换为 `AND NOT ( (ts BETWEEN '起1' AND '止1') OR (ts BETWEEN '起2' AND '止2') ... )`；
--         窗口为空时替换为**空串**（等价于不排除）—— 与 §6.1.1 分母口径一致。
--   ⇒ 查询本身仍是**本库单条**（不含跨库引用），T3 对**替换后**的语句计时。
-- EXPLAIN:（待月表有数据后实测填入）

SELECT
    COUNT(*)                                                              AS sessions,
    SUM(CASE WHEN j.result = 'success'
              AND j.duration_ms <= 300 THEN 1 ELSE 0 END)                 AS numerator,
    ROUND(
        SUM(CASE WHEN j.result = 'success' AND j.duration_ms <= 300
                 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0)
    , 4)                                                                  AS axis2_ratio
FROM (
    SELECT
        props->>'$.duration_ms'                AS duration_ms,
        props->>'$.result'                     AS result,
        props->>'$.fail_reason'                AS fail_reason,
        props->>'$.network_type'               AS network_type,
        ABS(CAST(props->>'$.t_cache_ms'  AS SIGNED)
          + CAST(props->>'$.t_net_ms'    AS SIGNED)
          + CAST(props->>'$.t_agg_ms'    AS SIGNED)
          + CAST(props->>'$.t_render_ms' AS SIGNED)
          - CAST(props->>'$.duration_ms' AS SIGNED)) AS seg_sum_diff
    FROM track_event_YYYYMM
    WHERE event_name = 'layer_switch'
      AND ts >= NOW() - INTERVAL 7 DAY
      /* RESTART_WINDOWS_EXCLUSION */
) j
WHERE COALESCE(j.fail_reason, '') <> 'cancelled'            -- 排除 ①
  AND COALESCE(j.network_type, 'unknown') NOT IN ('3g','2g','none')  -- 排除 ②
  AND j.seg_sum_diff <= 1;                                  -- 排除 ③（如 Q6 判据）


-- =============================================================================
-- Q3 · 轴③ 🟢 完整发布率
-- 看板项：§6.1 轴③
-- 口径  ：`post_published` 事件中 `completeness_level = 2`（🟢 完整档）的占比。
--         月表 `completeness_level` 为该事件的**维度快照列**（0=🔴 / 1=🟡 / 2=🟢），
--         无需读 `props`。
-- 常量  ：完整度三档判定见 PRD §9.8；权重 ×2/×1/×0.5
-- 备注  ：`post_published` 的属性在 openapi 中标注「Batch2 补充」，但本查询只用到
--         **月表列**（非 props），故 SQL 本身可执行；Batch1 无数据时结果为空集，
--         属「无数据」而非「查询不可执行」。
-- EXPLAIN:（待月表有数据后实测填入）

SELECT
    COUNT(*)                                                        AS published_total,
    SUM(CASE WHEN completeness_level = 2 THEN 1 ELSE 0 END)         AS published_green,
    ROUND(
        SUM(CASE WHEN completeness_level = 2 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    , 4)                                                            AS axis3_ratio
FROM track_event_YYYYMM
WHERE event_name = 'post_published'
  AND ts >= NOW() - INTERVAL 7 DAY;


-- =============================================================================
-- Q4 · 轴① 两项反向哨兵（§6.2）—— **Batch2 交付物（Batch1 不参与 T3，记 N/A）**
-- 看板项：§6.2
-- 口径  ：① 「联系后 7 天内该资源方被举报数」—— `report` 表按 `reported_user_id`
--         计数，与 `contact_event` 的同资源方关联；
--         ② 「同一资源方被重复联系、但无任何用户二次联系的占比」—— `contact_event`
--         按资源方聚合的复联留存率。
-- -----------------------------------------------------------------------------
-- 为何 Batch1 交付不了（2026-10-10 用户裁定：标为 Batch2 交付物）：
--   本项**双重依赖** —— ① 需 join **业务库** `report` 表（列 `reported_user_id` /
--   `created_at`，见 `V1__init_schema.sql` 第 261–279 行），属跨库；
--   ② 需「资源方标识」（`post_id` 或 `to_user_id`），而 `contact_event` 的属性按
--   openapi 标注为「Batch2 补充」，月表亦无 `post_id` 列。
--   又：轴① 的两项哨兵是对**轴① 指标**的旁证，轴① 本身 Batch1 不可测（见 Q1）。
--   ⇒ 与 Q1 同批：**Batch1 不参与 T3**，待 Batch2 属性清单定稿 + 跨库口径裁定后补写。
-- EXPLAIN:（Batch2 属性清单与跨库口径定稿后实测填入）


-- =============================================================================
-- Q5 · 图层切换 P95 耗时（工程 SLA，与轴② 分开）
-- 看板项：§6.3（告警线「P95 > 300ms」）
-- 常量  ：`NfrPerf.layerSwitchP95Ms` = 300
-- 口径  ：**只统计 success 会话**（分母排除同 Q2 的 ①②③；④ 重启窗口同 Q2 的
--         `/* RESTART_WINDOWS_EXCLUSION */` 两段式注入）。
--         本查询用窗口函数按 `duration_ms` 升序取第 `ceil(0.95*n)` 位，与端侧
--         「最近秩法 P95」口径一致（`LayerSwitchRecorder._p95`）。
-- 备注  ：工程 SLA 与轴② **是两条不同的线**（2026-09-02 定案），不得用其一推另一。
-- EXPLAIN:（待月表有数据后实测填入）

SELECT
    COUNT(*)                       AS sessions,
    MAX(CASE WHEN rk = p95_rank THEN duration_ms END) AS p95_ms
FROM (
    SELECT
        CAST(props->>'$.duration_ms' AS SIGNED)                              AS duration_ms,
        ROW_NUMBER() OVER (ORDER BY CAST(props->>'$.duration_ms' AS SIGNED)) AS rk,
        CEIL(0.95 * COUNT(*) OVER ())                                        AS p95_rank
    FROM track_event_YYYYMM
    WHERE event_name = 'layer_switch'
      AND props->>'$.result' = 'success'
      AND COALESCE(props->>'$.fail_reason', '') <> 'cancelled'
      AND COALESCE(props->>'$.network_type', 'unknown') NOT IN ('3g','2g','none')
      AND ts >= NOW() - INTERVAL 7 DAY
      /* RESTART_WINDOWS_EXCLUSION */
) t;


-- =============================================================================
-- Q6 · 四段和校验不过的事件数与占比（数据质量）
-- 看板项：§4.2
-- 口径  ：`ABS(t_cache_ms + t_net_ms + t_agg_ms + t_render_ms - duration_ms) > 1`
--         即判「校验不过」（容差 ±1ms）。四段与整段均取自 `props` JSON。
--         纯本库计算，**无跨库依赖、无窗口排除**（数据质量判据按全量看）。
-- 备注  ：这是**埋点数据质量**判据 —— 客户端漏计一段时，表现是「P95 突然变好」，
--         属最难发现的指标错误，故必须单独看板。
-- EXPLAIN:（待月表有数据后实测填入）

SELECT
    COUNT(*)                                                    AS total_sessions,
    SUM(CASE WHEN seg_sum_diff > 1 THEN 1 ELSE 0 END)           AS bad_sessions,
    ROUND(
        SUM(CASE WHEN seg_sum_diff > 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    , 4)                                                        AS bad_ratio
FROM (
    SELECT
        ABS(CAST(props->>'$.t_cache_ms'  AS SIGNED)
          + CAST(props->>'$.t_net_ms'    AS SIGNED)
          + CAST(props->>'$.t_agg_ms'    AS SIGNED)
          + CAST(props->>'$.t_render_ms' AS SIGNED)
          - CAST(props->>'$.duration_ms' AS SIGNED)) AS seg_sum_diff
    FROM track_event_YYYYMM
    WHERE event_name = 'layer_switch'
      AND ts >= NOW() - INTERVAL 7 DAY
) t;


-- =============================================================================
-- Q7 · `dropped_count` 队列溢出监控 —— **非 SQL 判据（日志扫描）**
-- 看板项：§4.6
-- -----------------------------------------------------------------------------
-- 2026-10-10 用户裁定：**按「日志扫描判据」执行**，不落表、不进本 SQL 文件。
--
-- 依据与理由：
--   · `dropped_count` 是**批次信封元数据**（`TrackBatch.toJson()` 只含 `events`
--     与 `dropped_count`），**不占事件条目**，故不在 `track_event_YYYYMM` 月表；
--   · 《可观测性架构方案》§4.6 原文即允许「服务端落一张极小的 `track_drop_stat`
--     表**或直接写日志**」；详设 §21 #5 与编码规范 §232/§288 已定 Batch1 取
--     「**落日志**」这一支 → 数据源是**应用日志**而非数据库；
--   · 故把它留在「看板 SQL 清单」里会让 T3 永远面对一个无判定对象 —— 这正是
--     「扫描面为空是 SKIP 不是 PASS」要防的假绿。
--
-- 判据（照 §4.6 告警线，执行者仍为定时任务 #8，**并入 T3 之外的一步**）：
--   ① 单用户单日 `dropped_count > 200`；
--   ② 全体用户单日丢弃总量 > 当日上报总量 × 5%；
--   任一条命中即写告警日志，并在轴② 结论中标注「本期数据受队列溢出影响」。
--   扫描对象 = 应用日志中 `track_drop_stat` 落日志行（详设 §21 #5）；
--   扫描面为空时记 **SKIP，不得记 PASS**。
--
-- ⚠️ 连带待办：本裁定使 §9.1.1 的「七条 SQL」实为「六条 SQL + 一条日志判据」，
--    该节清单表已同步标注（Q7 行改为「非 SQL 判据」）。
-- EXPLAIN:（无判定对象 —— 非 SQL）


-- =============================================================================
-- 文件结束。修订纪律：本文件为**单向出口**式的交付物，改动须同步
-- 《可观测性架构方案》§9.1.1 的清单表；任何口径裁定的结果须回写说明文档 §2.9。
-- =============================================================================
