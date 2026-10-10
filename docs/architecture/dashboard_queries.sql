-- =============================================================================
-- 主看板 SQL 清单（Q1–Q7）
-- =============================================================================
-- 交付物归属：《可观测性架构方案》§9.1.1（「这七条 SQL 本身是 Batch1 交付物，
--             须落在 docs/ 或 scripts/ 下的【单一文件】内」）。
-- 消费方    ：定时任务 #8「可观测性阈值巡检」的 **T3** 判据 —— 逐条执行本文件
--             的 SQL 并计时，任一条单次执行 > `NfrObs.MIGRATION_DASHBOARD_SQL_SECONDS`
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
-- ⚠️ 可执行性状态（2026-10-10 首次交付时如实标注 —— 「扫描面为空是 SKIP 不是 PASS」）
--
--   编号 | 看板项                  | 状态   | 说明
--   -----|------------------------|--------|------------------------------------------------
--   Q1   | §6.1 轴① 首次联系触发率 | 缺口   | 月表无 `post_id` 列；`contact_event` 属性按
--        |                        |        | openapi 标注为「Batch2 补充」，且轴① 本就
--        |                        |        | 「Batch2 上线后可测」（§6.1）→ 见 Q1 缺口块
--   Q2   | §6.1 轴② 图层切换成功率 | 部分   | 主体可算；但分母排除条件之一「落在
--        |                        |        | `restart_window` 内」需查**业务库**表，
--        |                        |        | 与「月表设计为免跨库 join」冲突 → 见 Q2 缺口块
--   Q3   | §6.1 轴③ 完整发布率     | 可执行 | 直接读 `completeness_level` 列
--   Q4   | §6.2 轴① 两项反向哨兵   | 缺口   | 需 `report` 表（业务库，跨库）+ `contact_event`
--        |                        |        | （Batch2）→ 见 Q4 缺口块
--   Q5   | §6.3 图层切换 P95 耗时  | 可执行 | 工程 SLA，与轴② 分开；读 `props` JSON
--   Q6   | §4.2 四段和校验不过     | 可执行 | 纯 `props` JSON 计算，无跨库
--   Q7   | §4.6 dropped_count 汇总  | 缺口   | `dropped_count` 是**批次信封元数据**，按
--        |                        |        | 详设 §21 #5 / 编码规范 §232·§288 在 Batch1
--        |                        |        | **落日志**，不落月表 → 见 Q7 缺口块
--
--   ⇒ T3 接线时只对「可执行」的 Q3 / Q5 / Q6 计时；Q1 / Q2 / Q4 / Q7 记
--     「SKIP —— 缺口未裁定」，**不得记为通过**（缺口裁定见说明文档 §2.9 DEC-18 后续）。
-- =============================================================================


-- =============================================================================
-- Q1 · 轴① 首次联系触发率
-- 看板项：§6.1 轴①；口径：PRD:2902「发布后 30 分钟内获得 ≥1 次联系点击的发布占比」
-- 常量  ：北极星轴① 目标分档见 §6.1（Batch1 不考核，见 §0.2.1 D1 兜底）
-- -----------------------------------------------------------------------------
-- ⚠️ 缺口（未裁定）：本查询需要「发布」与「联系」两侧都带 `post_id`，而
--    `track_event_YYYYMM` **没有 `post_id` 列**（公共列只有 event_name /
--    interaction_id / user_id / device_id / ts，维度快照只有 leaf_category_id /
--    completeness_level / is_ai_assisted / grid_id）。`post_published` 与
--    `contact_event` 的 `post_id` / `elapsed_min` / `channel_type` 只能落在
--    `props` JSON，而 openapi.yaml 把这两个事件的属性标注为「Batch2 补充」。
--    ⇒ 在属性清单定稿前本查询**不可执行**，故不写半成品 SQL（避免给 T3 一个
--      会报错的判定对象）。裁定后在此补写，形如：
--        SELECT ... FROM track_event_YYYYMM p JOIN track_event_YYYYMM c
--          ON JSON_UNQUOTE(p.props->>'$.post_id') = JSON_UNQUOTE(c.props->>'$.post_id')
--         WHERE p.event_name='post_published' AND c.event_name='contact_event'
--           AND TIMESTAMPDIFF(SECOND, p.ts, c.ts) BETWEEN 0 AND 1800 ...
-- EXPLAIN:（待属性清单定稿、月表有数据后实测填入）


-- =============================================================================
-- Q2 · 轴② 分类图层加载成功率（含分子/分母口径与全部排除条件）
-- 看板项：§6.1 轴②（口径明细见 §6.1.1）
-- 常量  ：`NfrPerf.layerSwitchP95Ms` = 300（分子判据线，单次布尔口径）、
--         `NfrObs.RESTART_WARMUP_MINUTES` = 5（重启窗口预热）
-- 口径  ：分子 = `result='success' AND duration_ms <= 300`；
--         分母 = 排除四类后的 `layer_switch` 会话数 —— ① `fail_reason='cancelled'`；
--         ② `network_type IN ('3g','2g','none')`（注意 `unknown` **不在**排除集）；
--         ③ 四段和校验不过（见 Q6）；④ 落在 `restart_window` 内。
-- -----------------------------------------------------------------------------
-- ⚠️ 缺口（未裁定）：排除条件 ③④ 无法在本库内完成 ——
--    · ③ 四段和校验需 `props` 内 5 个字段，可算，但按 §6.1.1 该条件属**分母排除**，
--      需与 Q6 用同一判据（本文件 Q6 已给出同一表达式，可内联复用）；
--    · ④ `restart_window` 表在**业务库**（`V2__restart_window.sql`），须跨库查询，
--      与「埋点月表设计目标：分析无需跨库 join」的取向冲突。
--    ⇒ 故本查询拆为 **Q2a（本库可执行，仅排除 ①②③）** 与 **Q2b（需跨库，暂缺）**：
--      T3 目前只对 Q2a 计时；Q2b 待裁定（迁移 `restart_window` 到埋点库 / 或由
--      巡检侧先取窗口再传入）后补写。
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
-- Q4 · 轴① 两项反向哨兵（§6.2）
-- 看板项：§6.2
-- 口径  ：① 「联系后 7 天内该资源方被举报数」—— `report` 表（业务库）按
--         `reported_user_id` 计数，与 `contact_event` 的同资源方关联；
--         ② 「同一资源方被重复联系、但无任何用户二次联系的占比」—— `contact_event`
--         按资源方聚合的复联留存率。
-- -----------------------------------------------------------------------------
-- ⚠️ 缺口（未裁定）：此项**双重不可执行** ——
--    · ① 需 join **业务库** `report` 表（列 `reported_user_id` / `created_at`，
--      见 `V1__init_schema.sql` 第 261–279 行），属跨库；
--    · ② 需「资源方标识」（`post_id` 或 `to_user_id`），而 `contact_event` 的属性
--      按 openapi 标注为「Batch2 补充」，月表亦无 `post_id` 列。
--    ⇒ 两项均待裁定（属性清单定稿 + 跨库口径）后补写。
-- EXPLAIN:（待属性清单与跨库口径定稿后实测填入）


-- =============================================================================
-- Q5 · 图层切换 P95 耗时（工程 SLA，与轴② 分开）
-- 看板项：§6.3（告警线「P95 > 300ms」）
-- 常量  ：`NfrPerf.layerSwitchP95Ms` = 300
-- 口径  ：**只统计 success 会话**（与轴② 同分母排除口径的 ①②③；④ 同 Q2b 缺口）。
--         本查询用 MySQL 8 窗口函数按 `duration_ms` 升序取第 ceil(0.95*n) 位，
--         与端侧「最近秩法 P95」口径一致（`LayerSwitchRecorder._p95`）。
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
) t;


-- =============================================================================
-- Q6 · 四段和校验不过的事件数与占比（数据质量）
-- 看板项：§4.2
-- 口径  ：`ABS(t_cache_ms + t_net_ms + t_agg_ms + t_render_ms - duration_ms) > 1`
--         即判「校验不过」（容差 ±1ms）。四段与整段均取自 `props` JSON。
--         纯本库计算，无跨库依赖。
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
-- Q7 · `dropped_count` 汇总（队列溢出监控）
-- 看板项：§4.6
-- 口径  ：单用户单日 `dropped_count > 200` 或全体单日丢弃总量 > 上报总量 5% 即告警。
-- 常量  ：`NfrTrack.trackQueueCapacity` = 2000（队列容量，达上限才产生丢弃）
-- -----------------------------------------------------------------------------
-- ⚠️ 缺口（未裁定）：`dropped_count` 是**批次信封元数据**（不占事件条目），
--    按详设 §21 #5 与编码规范 §232/§288，Batch1 的口径是**落日志**
--    （`track_drop_stat` 落日志），**不落 `track_event_YYYYMM` 月表**。
--    ⇒ 本判据当前的数据源是**应用日志**而非 SQL，故无法以 SQL 形式交付；
--      要么裁定「落一张 `track_drop_stat` 表」后在此补 SQL，要么把该条
--      从「看板 SQL」改为「日志扫描判据」并同步修订 §4.6 / §9.1.1。
-- EXPLAIN:（无判定对象）


-- =============================================================================
-- 文件结束。修订纪律：本文件为**单向出口**式的交付物，改动须同步
-- 《可观测性架构方案》§9.1.1 的清单表；任何「缺口」裁定的结果须回写说明文档 §2.9。
-- =============================================================================
