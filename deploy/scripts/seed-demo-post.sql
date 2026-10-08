-- =============================================================================
-- seed-demo-post.sql —— 业务可验证种子数据（一次性，非 Flyway 迁移）
--
-- 用途：prod 库 post 表为空，导致「探索页（地图/列表）切真后无任何数据可点，
--       详情页永远打不开」。本脚本灌入一批**结构完整、业务合法**的演示帖子，
--       让「真机全量功能验证」有数据可验。
--
-- 与 scripts/seed-perf.sql 的区别（勿混用）：
--   * seed-perf.sql = 压测专用，TRUNCATE 后灌 15 万行**合成**数据，坐标是
--     grid '0_0' 这类占位，脚本头明确警告「不得指向含业务数据的库」；
--   * 本脚本 = 业务演示专用，只插固定 id 段（9001 起），不 TRUNCATE，
--     坐标落在杭州/合肥真实城区，标题/描述/价格/完整度均为可读业务值。
--
-- 数据设计：
--   * 作者：1 条 demo user（id=9001）；无外键约束，但详情页要展示作者昵称，故须有；
--   * 帖子：30 条，id 固定 9001–9030（幂等重跑靠先删该段）；
--   * 类目：覆盖 5 大类（工作 101xx / 房屋 201xx-202xx / 车辆 301xx-302xx /
--     生活 401xx-402xx / 服务 501xx-502xx），leaf id 取自 V3__seed_category.sql；
--   * 坐标：杭州（120.14–120.17, 30.26–30.29）15 条 + 合肥（117.31–117.35,
--     31.88–31.92）15 条。两城各铺：App 用默认中心（杭州）或真实 GPS（合肥）
--     都能看到 Marker。铺幅约 ±2km，落在 5km 视野半径内；
--   * grid_id：由 lng/lat 按契约算法现算，见下方表达式注释，不手抄；
--   * 完整度：三档全覆盖（绿 2 / 黄 1 / 红 0），由 completeness_conditions 生成列派生；
--   * 状态：全部 status='active' 且 expire_at 为未来 7 天，确保被 /map/pins 与
--     /posts/search 的过滤条件（status + expire_at）命中。
--
-- 已知取舍（不影响详情页验证）：
--   * contact_value_enc 插占位 X'00'：该列 NOT NULL 且需 AEAD 密文，而造不出真密文。
--     详情页不消费本列；仅「联系中转页 → 取完整号码」会失败，属预期（联系方式属另一条链路）。
--
-- 执行方式（服务器上，DB 端口不对外，只能经容器执行）：
--   docker exec -i s2s-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
--     --default-character-set=utf8mb4 "$MYSQL_DATABASE" < seed-demo-post.sql
--
-- 回滚：DELETE FROM post WHERE id BETWEEN 9001 AND 9030;
--       DELETE FROM user WHERE id = 9001;
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
DELETE FROM post WHERE id BETWEEN 9001 AND 9030;
DELETE FROM `user` WHERE id = 9001;

-- -----------------------------------------------------------------------------
-- 2. demo 作者
-- -----------------------------------------------------------------------------
INSERT INTO `user` (id, phone_mask, nickname, realname_status, default_radius, key_version)
VALUES (9001, '138****9001', '找鸭找演示账号', 'passed', '5', 0);

-- -----------------------------------------------------------------------------
-- 3. 待灌帖子（临时表承载，便于审阅与复用 grid_id 计算表达式）
--    rf/ap/lm = completeness_conditions 的 required_full / address_precise / leaf_matched
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_seed_post;
CREATE TEMPORARY TABLE tmp_seed_post (
  seq        INT           NOT NULL,
  leaf       INT           NOT NULL,
  ptype      VARCHAR(16)   NOT NULL,
  title      VARCHAR(64)   NOT NULL,
  descr      TEXT          NOT NULL,
  lng        DECIMAL(10,6) NOT NULL,
  lat        DECIMAL(10,6) NOT NULL,
  price      DECIMAL(12,2) NULL,
  punit      VARCHAR(16)   NULL,
  addr       VARCHAR(128)  NULL,
  rf         TINYINT       NOT NULL,
  ap         TINYINT       NOT NULL,
  lm         TINYINT       NOT NULL
);

INSERT INTO tmp_seed_post
  (seq, leaf, ptype, title, descr, lng, lat, price, punit, addr, rf, ap, lm)
VALUES
  -- ── 杭州（默认中心 120.1551, 30.2741 周边）──
  (1,  10101, 'resource', '餐饮门店招服务员',   '城西连锁餐饮招全职服务员，包吃住，早晚班可选。', 120.15120, 30.27550, 5500.00, '月', '西湖区文三路 100 号', 1, 1, 1),
  (2,  10103, 'resource', '家庭日常保洁',       '三居室日常保洁，每周一次，自带工具。',           120.15840, 30.27180, 45.00,   '小时', '拱墅区莫干山路 88 号', 1, 1, 1),
  (3,  10202, 'demand',   '找周末兼职',         '周末两天找兼职，能吃苦，日结优先。',             120.14680, 30.27820, 200.00,  '天', '西湖区古墩路 12 号',   1, 1, 0),
  (4,  10301, 'demand',   '个人求职（家政）',   '从事家政五年，找长期稳定雇主。',                 120.16230, 30.26910, NULL,    NULL, NULL,                   1, 0, 0),
  (5,  20101, 'resource', '朝南主卧出租',       '地铁口朝南主卧，独立卫浴，拎包入住。',           120.14950, 30.27260, 1800.00, '月', '西湖区教工路 45 号',   1, 1, 1),
  (6,  20103, 'resource', '整租两室一厅',       '精装两室一厅整租，家电齐全，近地铁 2 号线。',     120.15670, 30.28030, 4200.00, '月', '拱墅区上塘路 200 号',  1, 1, 1),
  (7,  20201, 'demand',   '求租单间',           '求租地铁沿线单间，预算 1500 以内，可长租。',     120.14490, 30.27440, NULL,    NULL, NULL,                   1, 1, 0),
  (8,  30101, 'resource', '早晚通勤顺风车',     '工作日早 8 点城西到滨江，晚 6 点返回。',         120.15360, 30.27680, 15.00,   '次', '西湖区文一路 300 号',  1, 1, 1),
  (9,  30201, 'demand',   '求拼车周末往返',     '周六去临安，周日回，求顺路拼车。',               120.14720, 30.27030, 40.00,   '次', NULL,                   1, 0, 1),
  (10, 40101, 'resource', '闲置婴儿车转让',     '九成新婴儿推车，可折叠，低价出。',               120.16010, 30.27710, 260.00,  '件', '拱墅区湖墅南路 66 号', 1, 1, 1),
  (11, 40201, 'demand',   '求购二手书桌',       '求购 1.2 米实木书桌，成色好优先。',               120.14560, 30.26880, 300.00,  '件', NULL,                   1, 1, 0),
  (12, 50101, 'resource', '空调清洗维修上门',   '专业空调清洗加氟，市区两小时上门。',             120.15790, 30.27390, 120.00,  '次', '西湖区黄龙路 9 号',    1, 1, 1),
  (13, 50201, 'demand',   '求家教辅导',         '初二数学找一对一辅导，每周两次。',               120.15080, 30.28160, 200.00,  '小时', NULL,                 1, 0, 0),
  (14, 10104, 'resource', '仓库管理员招聘',     '物流园招仓管，需会简单电脑操作，五险一金。',     120.16320, 30.27120, 6000.00, '月', '拱墅区祥园路 18 号',   1, 1, 1),
  (15, 20102, 'resource', '次卧出租（限女生）', '合租次卧，室友均为女生，环境安静。',             120.14830, 30.27650, 1200.00, '月', '西湖区西溪路 55 号',   1, 1, 1),
  -- ── 合肥（真实 GPS 中心 117.3294, 31.9038 周边）──
  (16, 10101, 'resource', '餐饮后厨帮工',       '连锁快餐招后厨帮工，可培训，包午餐。',           117.32410, 31.90120, 4800.00, '月', '蜀山区长江西路 100 号', 1, 1, 1),
  (17, 10103, 'resource', '开荒保洁',           '新房开荒保洁，按面积计费，可当天上门。',         117.33260, 31.90640, 8.00,    '平方', '蜀山区潜山路 88 号',   1, 1, 1),
  (18, 10203, 'demand',   '找小时工',           '找钟点工，每天下午两小时，做家务。',             117.32180, 31.89980, 40.00,   '小时', NULL,                   1, 1, 0),
  (19, 20101, 'resource', '主卧出租近地铁',     '一号线地铁口主卧，带飘窗，随时看房。',           117.33540, 31.90420, 1500.00, '月', '包河区马鞍山路 12 号', 1, 1, 1),
  (20, 20103, 'resource', '整租三室两厅',       '政务区三室两厅，精装修，家电全新。',             117.31820, 31.90810, 3800.00, '月', '蜀山区望江西路 300 号', 1, 1, 1),
  (21, 20201, 'demand',   '求租合租房间',       '求租合租单间，预算 1000 内，近地铁优先。',       117.32890, 31.89620, NULL,    NULL, NULL,                   1, 1, 0),
  (22, 30101, 'resource', '周末顺风车往返',     '周五晚合肥到南京，周日晚返回。',                 117.34010, 31.90270, 80.00,   '次', '瑶海区长江东大街 45 号', 1, 0, 1),
  (23, 30202, 'demand',   '求拼车去机场',       '周一早上 7 点去新桥机场，求顺路。',              117.32650, 31.91030, 60.00,   '次', NULL,                   1, 0, 0),
  (24, 40102, 'resource', '闲置跑步机转让',     '家用跑步机，买来没用几次，自提。',               117.31430, 31.90060, 800.00,  '台', '蜀山区黄山路 66 号',   1, 1, 1),
  (25, 40202, 'demand',   '求购二手冰箱',       '求购双门冰箱，成色好，能自提。',                 117.33760, 31.89790, 600.00,  '台', NULL,                   1, 1, 0),
  (26, 50101, 'resource', '上门家电维修',       '冰箱洗衣机热水器维修，十年经验。',               117.32270, 31.90540, 80.00,   '次', '庐阳区阜阳路 200 号',  1, 1, 1),
  (27, 50301, 'demand',   '求搬家服务',         '本月末搬家，三居室，求报价。',                   117.33080, 31.91260, NULL,    NULL, NULL,                   1, 0, 0),
  (28, 10102, 'resource', '商场导购招聘',       '商场品牌专柜招导购，底薪加提成。',               117.34320, 31.90080, 5000.00, '月', '瑶海区站前路 8 号',    1, 1, 1),
  (29, 20102, 'resource', '次卧合租',           '三室合租中的次卧，室友好相处。',                 117.31640, 31.90690, 1000.00, '月', '蜀山区合作化南路 22 号', 1, 1, 1),
  (30, 40103, 'resource', '九成新书桌转让',     '实木书桌，尺寸 1.4 米，低价转让。',              117.32590, 31.89350, 200.00,  '张', '包河区望江东路 55 号', 1, 1, 1);

-- -----------------------------------------------------------------------------
-- 4. 写入 post
--    grid_id 由 lng/lat 按契约算法现算（openapi `/map/pins` description）：
--      gx = floor( floor(lng * 1e6) / 4500 )，gy 同理，编码 "gx_gy"
--    0.0045° = 4500 微度（1e-6 度），floor 向负无穷（SQL FLOOR 即此语义）。
--    自检向量：lng=120.15, lat=30.28 → 26700_6728（与契约 10 向量一致）。
-- -----------------------------------------------------------------------------
INSERT INTO post (
  id, user_id, type, leaf_category_id, title, `desc`, grid_id,
  price, price_unit, lng, lat, address, template_values,
  contact_channel, contact_value_enc, completeness_conditions,
  restricted, status, status_reason, status_changed_at,
  template_version, risk_score, expire_at, version, key_version
)
SELECT
  9000 + t.seq,
  9001,
  t.ptype,
  t.leaf,
  t.title,
  t.descr,
  CONCAT(
    CAST(FLOOR(FLOOR(t.lng * 1000000) / 4500) AS SIGNED), '_',
    CAST(FLOOR(FLOOR(t.lat * 1000000) / 4500) AS SIGNED)
  ),
  t.price,
  t.punit,
  t.lng,
  t.lat,
  t.addr,
  JSON_OBJECT(),
  'phone',
  X'00',
  JSON_OBJECT(
    'required_full',   t.rf = 1,
    'address_precise', t.ap = 1,
    'leaf_matched',    t.lm = 1
  ),
  0,
  'active',
  NULL,
  NOW(),
  1,
  0,
  DATE_ADD(NOW(), INTERVAL 7 DAY),
  0,
  0
FROM tmp_seed_post t;

DROP TEMPORARY TABLE IF EXISTS tmp_seed_post;

-- -----------------------------------------------------------------------------
-- 5. 自检（执行后应看到 user=1 行、post=30 行、completeness_level 三档齐全）
-- -----------------------------------------------------------------------------
SELECT 'seed 完成' AS step,
       (SELECT COUNT(*) FROM user WHERE id = 9001)                              AS demo_user,
       (SELECT COUNT(*) FROM post WHERE id BETWEEN 9001 AND 9030)               AS demo_post,
       (SELECT COUNT(DISTINCT completeness_level) FROM post
         WHERE id BETWEEN 9001 AND 9030)                                        AS completeness_levels;
