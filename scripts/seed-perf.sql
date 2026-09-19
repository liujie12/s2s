-- =============================================================================
-- seed-perf.sql —— 性能验收专用造数脚本（Batch1 交付物）
--
-- 依据（架构 §10.3.2「索引验收的造数规格与判据」）：
--   * 数据量   ：post 表 10 万行有效帖（status='active' 且未过期）
--                + 5 万行已过期或已下架（各 2.5 万，验证过滤有效性）
--   * 网格分布 ：grid_id 覆盖 200 个网格，长尾形态——最热网格 3000 行、
--                中位网格约 300 行（均匀分布会让索引看起来比实际好）
--   * 类目分布 ：leaf_category_id 覆盖分类树全部 48 个叶子，最热类目 10101 占 15%
--   * 确定性   ：全部取模造数、无 RAND()，两次执行结果分布逐位一致
--                （expire_at 以 NOW() 锚定保证「未过期」语义永真，先例同款）
--   * 500 上限 ：最热组合（grid='0_0' × leaf=10101 × 单 type）有效行约 1000，
--                满足 §10.3.5 响应体积验收「打满 500 条再量」的构造前提
--
-- ⚠️ 副作用警告：本脚本会 TRUNCATE 清空 post 表后重建 15 万行。
--    目标库是本地压测/索引验收专用库 s2s_batch1（先例 docs/database/scripts/
--    explain_pins_real.sh 同样以 TRUNCATE 起步），不得指向含业务数据的库。
--
-- 执行方式（编码规范 §6：头部带库名断言，库名不符立即中止）：
--   mysql -h127.0.0.1 -uroot -p --default-character-set=utf8mb4 s2s_batch1 \
--         < scripts/seed-perf.sql
--
-- 叶子类目唯一真源：lib/domain/category_tree.dart（48 项，§2.3「不超过 60 个」）。
-- 本脚本不依赖 category 表行数（该表种子由后续迁移负责，与本造数无关）。
-- =============================================================================

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- 0. 库名断言（fail-fast）：当前库不是 s2s_batch1 时，往 NOT NULL 列插 NULL
--    触发 ERROR 1048 使 mysql 客户端中止，防止误清业务库。
-- -----------------------------------------------------------------------------
SELECT '库名断言：期望 s2s_batch1，实际 = ' AS db_assert_msg, DATABASE() AS actual_db
WHERE DATABASE() <> 's2s_batch1';

DROP TEMPORARY TABLE IF EXISTS tmp_perf_db_assert;
CREATE TEMPORARY TABLE tmp_perf_db_assert (msg VARCHAR(200) NOT NULL);
INSERT INTO tmp_perf_db_assert (msg)
SELECT NULL WHERE DATABASE() <> 's2s_batch1';
DROP TEMPORARY TABLE IF EXISTS tmp_perf_db_assert;

-- -----------------------------------------------------------------------------
-- 1. 幂等清空（可重复执行前提：两轮验收跑在同一份确定分布上，结论才可比）
-- -----------------------------------------------------------------------------
TRUNCATE TABLE post;

-- -----------------------------------------------------------------------------
-- 2. 叶子类目清单（48 项，取自 lib/domain/category_tree.dart 逐字抄录）
--    seq=0 保留给倾斜类目 10101（不参与轮转）；seq=1..47 供确定性轮转取用。
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_perf_leaf;
CREATE TEMPORARY TABLE tmp_perf_leaf (
  seq     INT PRIMARY KEY,
  leaf_id INT NOT NULL
);
INSERT INTO tmp_perf_leaf (seq, leaf_id) VALUES
  (0,  10101), (1,  10102), (2,  10103), (3,  10104), (4,  10105),
  (5,  10201), (6,  10202), (7,  10203), (8,  10301),
  (9,  20101), (10, 20102), (11, 20103), (12, 20201), (13, 20301), (14, 20401),
  (15, 30101), (16, 30102), (17, 30103), (18, 30201), (19, 30202), (20, 30301),
  (21, 30401),
  (22, 40101), (23, 40102), (24, 40103), (25, 40104), (26, 40105), (27, 40201),
  (28, 40202), (29, 40203), (30, 40301), (31, 40302), (32, 40401), (33, 40402),
  (34, 40501), (35, 40502),
  (36, 50101), (37, 50102), (38, 50103), (39, 50201), (40, 50202), (41, 50203),
  (42, 50301), (43, 50302), (44, 50401), (45, 50402), (46, 50501), (47, 50502);

-- -----------------------------------------------------------------------------
-- 3. 造数主体：150,000 行确定性长尾分布
--
--    n = 0..149999，全模运算分桶（数值推导见各 CASE 行内注释）：
--      网格    n%100<10        → 热点 5 格（n%5），各 3000 = 15,000（10%）
--             10<=n%100<67     → 中位 45 格（5+(n DIV 100)%45），各约 1900 = 85,500（57%）
--             67<=n%100<100    → 长尾 150 格（50+(n DIV 100)%150），各 330 = 49,500（33%）
--      类目    n%100<6          → 10101（热点组 60%）
--             其余 n%10=0      → 10101（非热点组 10%）；合计 22,500 = 15.0% 精确
--             其余行           → 47 叶子按 (n DIV 10)%47 确定性轮转
--      有效性  n%6=3            → archived（已下架，25,000）
--             n%6=0            → active + expire_at 过期（25,000，验证过滤列有效）
--             其余 n%3<>0      → active 未过期（100,000 有效帖）
--      类型    FLOOR(n/1000)%2  → resource/demand 对半，千行块与网格/类目模数独立
--
--    禁入 INSERT 的 STORED 生成列：l2_category_id、completeness_level
--    （编码规范 §4.9：生成列入 insert/update SQL 会 ERROR 3105）。
-- -----------------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 150000;

INSERT INTO post (
  user_id, type, leaf_category_id, title, `desc`, grid_id, lng, lat,
  contact_channel, contact_value_enc, completeness_conditions, status,
  template_version, expire_at, key_version
)
WITH RECURSIVE seq(n) AS (
  SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 149999
),
shaped AS (
  SELECT
    n,
    -- 网格序号 0..199：热点 n%100<10 时 n%5 覆盖 0..4（每格 2 桶×1500=3000）
    CASE
      WHEN n % 100 < 10 THEN n % 5
      WHEN n % 100 < 67 THEN 5 + (n DIV 100) % 45
      ELSE 50 + (n DIV 100) % 150
    END AS grid_no,
    -- 叶子类目：10101 双支倾斜（热点组 60% + 非热点组 10% = 全表 15.0%）
    CASE
      WHEN n % 100 < 6 THEN 10101
      WHEN n % 10 = 0  THEN 10101
      ELSE (SELECT leaf_id FROM tmp_perf_leaf WHERE seq = (n DIV 10) % 47 + 1)
    END AS leaf_id,
    -- 供需态：与 n%100 / n%10 / n%5 模数均独立（1000 = 10×100 整除覆盖）
    IF(FLOOR(n / 1000) % 2 = 0, 'resource', 'demand') AS post_type,
    -- 有效性三分桶（expired_active 为中间态标记，最终映射回 ENUM 'active'）
    CASE
      WHEN n % 6 = 3 THEN 'archived'
      WHEN n % 6 = 0 THEN 'expired_active'
      ELSE 'active'
    END AS bucket
  FROM seq
)
SELECT
  (n % 10000) + 1,                                        -- user_id：1 万发布者轮转
  post_type,
  leaf_id,
  CONCAT('性能造数_', n),                                  -- title：确定性可追溯
  '性能验收造数描述（中等长度，避免行宽失真歪曲容量估算，R15 教训）。',
  CONCAT(grid_no, '_0'),                                   -- grid_id：gx_0 形态，入参正则兼容
  116.0 + grid_no * 0.0045 + (n % 45) / 10000,             -- lng：格内微散布，DECIMAL(10,6)
  39.0 + (n % 89) / 10000,                                 -- lat：同格微散布
  'phone',
  UNHEX('00'),                                             -- 密文占位（先例同款，不走 CryptoFacade）
  JSON_OBJECT(
    'required_full',   n % 2 = 0,
    'address_precise', n % 4 <> 0,
    'leaf_matched',    n % 5 < 3
  ),                                                       -- 三条件派生 completeness_level 0/1/2 三档健康
  CASE WHEN bucket = 'expired_active' THEN 'active' ELSE bucket END,
  1,                                                       -- template_version
  CASE
    WHEN bucket = 'archived'      THEN DATE_ADD(NOW(), INTERVAL 14 DAY)
    WHEN bucket = 'expired_active' THEN DATE_SUB(NOW(), INTERVAL 30 DAY)
    ELSE DATE_ADD(NOW(), INTERVAL 1 + n % 14 DAY)           -- 有效帖：未来 1..14 天
  END,
  0                                                        -- key_version（post 表无 DEFAULT，显式给 0）
FROM shaped;

DROP TEMPORARY TABLE IF EXISTS tmp_perf_leaf;

-- -----------------------------------------------------------------------------
-- 4. 更新优化器统计信息（EXPLAIN rows 估算的准确性前提）
-- -----------------------------------------------------------------------------
ANALYZE TABLE post;

-- -----------------------------------------------------------------------------
-- 5. 分布自检（期望值写在行内注释，逐项人工比对；数值偏离即造数缺陷）
-- -----------------------------------------------------------------------------
-- 5.1 总量与有效性三分：期望 150000 / 100000 / 25000 / 25000
SELECT COUNT(*)                                            AS total_rows,
       SUM(status = 'active' AND expire_at > NOW())        AS valid_rows,
       SUM(status = 'active' AND expire_at <= NOW())       AS expired_active_rows,
       SUM(status = 'archived')                            AS archived_rows
FROM post;

-- 5.2 网格覆盖：期望 200；最热 TOP5 各 3000；中位（第 100 小）≈330
SELECT COUNT(DISTINCT grid_id) AS distinct_grids FROM post;

SELECT grid_id, COUNT(*) AS cnt FROM post
GROUP BY grid_id ORDER BY cnt DESC, grid_id LIMIT 6;

SELECT grid_id, COUNT(*) AS median_grid_cnt FROM post
GROUP BY grid_id ORDER BY median_grid_cnt ASC, grid_id LIMIT 1 OFFSET 99;

-- 5.3 类目覆盖与倾斜：期望 48 叶子全出现；10101 占比 15.0
SELECT COUNT(DISTINCT leaf_category_id)              AS distinct_leaves,
       ROUND(100.0 * SUM(leaf_category_id = 10101) / COUNT(*), 1) AS hot_leaf_pct
FROM post;

-- 5.4 最热组合（§10.3.5 响应体积验收的构造点）：期望 0_0×10101 两 type 各约 1000（>500）
SELECT grid_id, leaf_category_id, type, COUNT(*) AS cnt FROM post
WHERE status = 'active' AND expire_at > NOW()
GROUP BY grid_id, leaf_category_id, type
ORDER BY cnt DESC LIMIT 3;

-- -----------------------------------------------------------------------------
-- 6. idx_pins_cover 覆盖索引 EXPLAIN（真实响应契约六列，PRD §6.10 pins[] schema）
--    判据（架构 §10.3.2，任一不满足即 FAIL）：
--      ① EXPLAIN.type != 'ALL'（无全表扫描）
--      ② EXPLAIN.key = 'idx_pins_cover'（命中预期索引）
--      ③ EXPLAIN.rows < 150000 × 5% = 7500（估算行数低于表总量 5%）
--    期望 Extra 含 'Using index'（index-only scan 不回表，R15 结论）。
-- -----------------------------------------------------------------------------
SELECT grid_id, leaf_category_id, type, COUNT(*) AS cnt
INTO @hot_grid, @hot_leaf, @hot_type, @hot_cnt
FROM post
WHERE status = 'active' AND expire_at > NOW()
GROUP BY grid_id, leaf_category_id, type
ORDER BY cnt DESC
LIMIT 1;

SELECT @hot_grid AS hot_grid, @hot_leaf AS hot_leaf,
       @hot_type AS hot_type, @hot_cnt AS hot_rows_gt_500_required;

EXPLAIN SELECT id, lng, lat, leaf_category_id, type, completeness_level
FROM post
WHERE grid_id = @hot_grid
  AND leaf_category_id = @hot_leaf
  AND type = @hot_type
  AND status = 'active'
  AND expire_at > NOW();

-- 反例对照（R15 方法论）：SELECT * 缺少覆盖列须回表，Extra 不得含 'Using index'
EXPLAIN SELECT * FROM post
WHERE grid_id = @hot_grid
  AND leaf_category_id = @hot_leaf
  AND type = @hot_type
  AND status = 'active'
  AND expire_at > NOW();

-- 多网格 IN（真实视野多格聚合，9 格）：同样须命中 idx_pins_cover
EXPLAIN SELECT id, lng, lat, leaf_category_id, type, completeness_level
FROM post
WHERE grid_id IN ('0_0','1_0','2_0','3_0','4_0','5_0','6_0','7_0','8_0')
  AND leaf_category_id = @hot_leaf
  AND type = @hot_type
  AND status = 'active'
  AND expire_at > NOW();

-- 造数完成
SELECT 'seed-perf DONE：150,000 行已就位，逐项核对上述自检期望值' AS done_msg;
