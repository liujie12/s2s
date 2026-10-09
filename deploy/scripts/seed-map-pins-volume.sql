-- =============================================================================
-- seed-map-pins-volume.sql —— /map/pins 响应体积验收（《系统总体架构设计文档》
-- §10.3.5）专用造数脚本
--
-- 用途：§10.3.5 明文规定「必须构造返回条数达上限 500 条的请求（用 §10.3.2 中最热
--       网格）；返回 20 条时体积当然达标，那不构成验收」。验收条目 [143] 要求在
--       真实环境实测 `GET /map/pins` 在 500 条时的 gzip 后体积与解压后体积。
--       本脚本在【单个网格】内灌入 500 条结构合法、必被 /map/pins 命中的帖子，
--       使一次请求恰好返回 500 条（服务端 SQL `LIMIT 500`，见 MapPostMapper.xml）。
--
-- 与另两个脚本的边界（勿混用）：
--   * seed-demo-post.sql  = 业务演示数据（30 条，杭州/合肥真实城区），供真机功能验证；
--   * seed-perf.sql       = §10.3.2 索引验收造数（10 万行 / 200 网格 / 长尾分布），
--                           **尚未交付**，本脚本【不是】它的替代品，不承担索引验收；
--   * 本脚本             = 仅服务「500 条响应体积」这一条验收，500 行、单网格。
--
-- 数据设计（全部可与 SQL 逐位核对）：
--   * 作者：user id = 9500（本脚本自建，幂等）；
--   * 帖子：500 条，id 固定 9501–9600（幂等重跑靠先删该段）；
--   * 坐标：经度 120.150000 + k*1e-6（k=0..499 → 120.150000–120.150499），
--           纬度 30.276000  + k*1e-6（k=0..499 → 30.276000–30.276499）；
--           这 500 个坐标【全部落在同一网格】 grid_id = 26700_6728：
--             gx = floor( floor(120.150499*1e6) / 4500 ) = floor(120150499/4500) = 26700
--             gy = floor( floor(30.276499 *1e6) / 4500 ) = floor(30276499 /4500) = 6728
--           与契约测试向量 (120.15, 30.28) → 26700_6728 同格，故 radius=1（n=2，
--           含中心格的 5×5=25 格）即可命中全部 500 条；
--   * 类目：leaf_category_id = 10101（工作·全职招聘·餐饮服务，见 V3__seed_category.sql）；
--   * 类型：type = 'resource'（与请求参数 post_type=resource 对应）；
--   * 状态：status='active' 且 expire_at 为未来 30 天 → 必被
--           `status='active' AND expire_at > NOW()` 命中；
--   * 完整度：三条件全 true → completeness_level 生成列为 2（绿），
--             与 §10.3.5 期望的响应字段形态一致。
--
-- 已知取舍：
--   * contact_value_enc 插占位 X'00'：该列 NOT NULL 且需 AEAD 密文，造不出真密文。
--     /map/pins 不消费该列，无影响；
--   * 显式指定 id 会把 post 表 AUTO_INCREMENT 抬到 9601（与 seed-demo-post.sql 同性质），
--     用户 id 会把 user 表抬到 9501。这是「可确定性回滚」的代价，非缺陷。
--
-- 执行方式（服务器上，DB 端口不对外，只能经容器执行）：
--   docker exec -i s2s-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
--     --default-character-set=utf8mb4 "$MYSQL_DATABASE" < seed-map-pins-volume.sql
--
-- 回滚（验收取完证据后应执行，使 [144] 的采集窗口回到业务数据状态）：
--   DELETE FROM post WHERE id BETWEEN 9501 AND 9600;
--   DELETE FROM `user` WHERE id = 9500;
--   （等价于本脚本第 1 段，直接重跑本脚本亦会先清后灌）
-- =============================================================================

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- 0. 库名断言（fail-fast）：当前库不是 s2s 时，往 NOT NULL 列插 NULL 触发
--    ERROR 1048 使 mysql 客户端中止，防止误灌业务库。
--    若你的环境 MYSQL_DATABASE 不是 s2s，请同步改此处的期望值。
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_seed_db_assert;
CREATE TEMPORARY TABLE tmp_seed_db_assert (msg VARCHAR(200) NOT NULL);
INSERT INTO tmp_seed_db_assert (msg)
SELECT NULL WHERE DATABASE() <> 's2s';
DROP TEMPORARY TABLE IF EXISTS tmp_seed_db_assert;

-- -----------------------------------------------------------------------------
-- 1. 幂等清空本脚本的数据段（只动固定 id 段，不碰任何其它行）
-- -----------------------------------------------------------------------------
DELETE FROM post WHERE id BETWEEN 9501 AND 9600;
DELETE FROM `user` WHERE id = 9500;

-- -----------------------------------------------------------------------------
-- 2. 造数作者（/map/pins 不读作者，仅为 user_id 外键语义完整）
-- -----------------------------------------------------------------------------
INSERT INTO `user` (id, phone_mask, nickname, realname_status, default_radius, key_version)
VALUES (9500, '138****9500', '响应体积验收造数账号', 'passed', '5', 0);

-- -----------------------------------------------------------------------------
-- 3. 生成 500 组成对坐标（seq 1..500，恒定落同一网格，见文件头推导）
--    用 10×10×5 的笛卡尔积生成 0..499 的序号 k，避免手写 500 行 VALUES，
--    也避免依赖递归 CTE 语法（可移植到任意 MySQL 8.x）。
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_seed_pins;
CREATE TEMPORARY TABLE tmp_seed_pins (
  seq INT           NOT NULL,
  lng DECIMAL(10,6) NOT NULL,
  lat DECIMAL(10,6) NOT NULL
);

INSERT INTO tmp_seed_pins (seq, lng, lat)
SELECT
  ones.d + tens.d * 10 + hundreds.d * 100 + 1                       AS seq,
  120.150000 + (ones.d + tens.d * 10 + hundreds.d * 100) * 0.000001 AS lng,
   30.276000 + (ones.d + tens.d * 10 + hundreds.d * 100) * 0.000001 AS lat
FROM
  (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS ones
CROSS JOIN
  (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS tens
CROSS JOIN
  (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4)      AS hundreds;

-- -----------------------------------------------------------------------------
-- 4. 写入 post
--    grid_id 由 lng/lat 按契约算法现算（openapi `/map/pins` description）：
--      gx = floor( floor(lng * 1e6) / 4500 )，gy 同理，编码 "gx_gy"
--    取自临时表的 DECIMAL(10,6) 列（非重复的浮点表达式），确保写入值与
--    网格计算用的是同一个数，不会因取整差异分处两格。
-- -----------------------------------------------------------------------------
INSERT INTO post (
  id, user_id, type, leaf_category_id, title, `desc`, grid_id,
  price, price_unit, lng, lat, address, template_values,
  contact_channel, contact_value_enc, completeness_conditions,
  restricted, status, status_reason, status_changed_at,
  template_version, risk_score, expire_at, version, key_version
)
SELECT
  9500 + t.seq,
  9500,
  'resource',
  10101,
  CONCAT('gzip 体积验收造数帖 #', t.seq),
  '仅用于 /map/pins 响应体积验收（§10.3.5），属造数数据，非业务内容。',
  CONCAT(
    CAST(FLOOR(FLOOR(t.lng * 1000000) / 4500) AS SIGNED), '_',
    CAST(FLOOR(FLOOR(t.lat * 1000000) / 4500) AS SIGNED)
  ),
  1000.00 + t.seq,
  '月',
  t.lng,
  t.lat,
  '西湖区文三路 1 号',
  JSON_OBJECT(),
  'phone',
  X'00',
  -- JSON 列直接灌「JSON 字面量字符串」：MySQL 落库时会把它解析为真正的 JSON
  -- 布尔 true。不能用 JSON_OBJECT('k', true) —— SQL 的 true 就是整数 1，
  -- 那会存成 JSON 数字 1，而生成列判据是 JSON_UNQUOTE(...) = 'true'，档位将恒为 0。
  '{"required_full": true, "address_precise": true, "leaf_matched": true}',
  0,
  'active',
  NULL,
  NOW(),
  1,
  0,
  DATE_ADD(NOW(), INTERVAL 30 DAY),
  0,
  0
FROM tmp_seed_pins t;

DROP TEMPORARY TABLE IF EXISTS tmp_seed_pins;

-- -----------------------------------------------------------------------------
-- 5. 自检（执行后应看到 pins=500、单一网格、单类目、单类型）
-- -----------------------------------------------------------------------------
SELECT 'seed 完成' AS step,
       (SELECT COUNT(*) FROM post WHERE id BETWEEN 9501 AND 9600)          AS seeded_pins,
       (SELECT COUNT(DISTINCT grid_id) FROM post WHERE id BETWEEN 9501 AND 9600) AS distinct_grids,
       (SELECT MIN(grid_id) FROM post WHERE id BETWEEN 9501 AND 9600)      AS grid_id,
       (SELECT COUNT(*) FROM post
         WHERE id BETWEEN 9501 AND 9600
           AND status = 'active' AND expire_at > NOW()
           AND leaf_category_id = 10101 AND type = 'resource')             AS hit_by_pins_query;
