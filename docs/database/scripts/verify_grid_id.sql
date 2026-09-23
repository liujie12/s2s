-- =============================================================================
-- grid_id 三端对拍——SQL 端（详设 §5.4.1 / 编码规范 §7.2-③）
--
-- 与 Dart `lib/core/cache/grid_id.dart`、Java `GridIdCalculator` 共用同一份 10 条
-- 向量，任一端不过即视为实现错误。
--
-- 关键区别（为什么 SQL 端不需要浮点补偿）：
--   生产路径 grid_id 由应用层 Java 用 double 计算写入 post.grid_id；double 对
--   0.00450 的表示略小于精确值，故 Java/Dart 端须加 FLOOR_EPSILON(1e-9) 补偿。
--   本脚本的 lng/lat 是 DECIMAL(10,6) 精确算术，`0.00450 * 100000` 恒为 450.000000，
--   无舍入误差，故不加补偿——补偿只服务于 double 端，恰好与精确 DECIMAL 对齐。
--
-- 第 9 条 (-0.000015,-0.000015) 是唯一能暴露「用截断代替 floor」的向量：最终
-- grid_id 偶然正确（截断/floor 都落到 -1_-1），必须额外断言中间微度值 == -2。
-- =============================================================================

SELECT
  v.lng,
  v.lat,
  v.expected,
  FLOOR(v.lng * 100000) AS lng_micro,
  FLOOR(v.lat * 100000) AS lat_micro,
  CONCAT(FLOOR(FLOOR(v.lng * 100000) / 450), '_',
         FLOOR(FLOOR(v.lat * 100000) / 450)) AS computed,
  CASE WHEN CONCAT(FLOOR(FLOOR(v.lng * 100000) / 450), '_',
                   FLOOR(FLOOR(v.lat * 100000) / 450)) = v.expected
       THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
  SELECT 120.15000 AS lng, 30.28000 AS lat, '26700_6728' AS expected
  UNION ALL SELECT 0, 0, '0_0'
  UNION ALL SELECT 0.00450, 0.00450, '1_1'
  UNION ALL SELECT 0.00449, 0.00449, '0_0'
  UNION ALL SELECT -0.00001, -0.00001, '-1_-1'
  UNION ALL SELECT -0.00450, -0.00450, '-1_-1'
  UNION ALL SELECT -0.00451, -0.00451, '-2_-2'
  UNION ALL SELECT 0.004500049, 0.004500049, '1_1'
  UNION ALL SELECT -0.000015, -0.000015, '-1_-1'
  UNION ALL SELECT 120.15000, -30.28000, '26700_-6729'
) AS v;

-- 第 9 条探针（必须返回 -2，而非 0 或 -1）：
SELECT -0.000015 AS lng, FLOOR(-0.000015 * 100000) AS expected_lng_micro_eq_neg2;
