-- =============================================================================
-- V21__category_l2_icon.sql — 二级类目补图标（PRD §6.4.2 二级图标映射表，2026-10-28 定稿）
-- =============================================================================
-- 背景：V3 灌种子时二级行「无配色 / 图标 / 认证」—— 当时 PRD 只有 5 个一级图标。
-- 2026-10-28 PRD §6.4.2 定稿 21 行二级图标表后，图标不再只是渲染常量，而是
-- **类目数据**：DB `category.icon`（V1 DDL 注释「Material Symbols 图标名」）
-- → `GET /categories/tree`（`CategoryNodeDto.icon`，`CategoryService#toDto` 已透传）
-- → 客户端 `CategoryNode.icon` → 筛选面板 / 发布页并排渲染。
-- 本迁移只补数据：不改表结构、不改后端代码。
--
-- 取值口径：逐行取自 PRD §6.4.2「二级图标映射表」的 `Material 名` 列，
-- **不得按印象改值**；与 `lib/domain/listing_category_style.dart` 的本地映射同源
-- （后者是离线 / 树版本落后时的兜底，不是第二真源）。
--
-- 为什么必须同时 bump `category_tree_version`：客户端按版本协商（§2.9 / §12.3），
-- 版本不变时服务端回 `data=null`，已有缓存的客户端永远看不到新 icon。
-- 版本格式沿用 DDL 口径 `YYYY-MM-DD.N`（同日递增 N、跨日重置 .1）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 二级类目图标（21 行）：编号 / 名称 / Material 名逐行对齐 PRD §6.4.2
-- -----------------------------------------------------------------------------
UPDATE `category`
SET `icon` = CASE `id`
    -- 工作
    WHEN 101 THEN 'work'                 -- 全职招聘（与一级同形，母题下沉）
    WHEN 102 THEN 'work_history'         -- 兼职/临时工
    WHEN 103 THEN 'person_search'        -- 求职找工作
    -- 房屋
    WHEN 201 THEN 'apartment'            -- 整租/合租
    WHEN 202 THEN 'real_estate_agent'    -- 求租/找房
    WHEN 203 THEN 'hotel'                -- 短租/日租
    WHEN 204 THEN 'support_agent'        -- 租房信息咨询
    -- 车辆
    WHEN 301 THEN 'airport_shuttle'      -- 顺风车/拼车
    WHEN 302 THEN 'car_rental'           -- 租车/借车
    WHEN 303 THEN 'sell'                 -- 二手车转让
    WHEN 304 THEN 'hail'                 -- 求搭车/求拼
    -- 生活
    WHEN 401 THEN 'inventory_2'          -- 二手闲置转让
    WHEN 402 THEN 'volunteer_activism'   -- 借物/互助（与一级同形）
    WHEN 403 THEN 'search'               -- 寻物启事/失物招领
    WHEN 404 THEN 'pets'                 -- 宠物相关
    WHEN 405 THEN 'campaign'             -- 求购/求助
    -- 服务
    WHEN 501 THEN 'cleaning_services'    -- 家政/保洁
    WHEN 502 THEN 'home_repair_service'  -- 维修/安装
    WHEN 503 THEN 'school'               -- 教学/培训
    WHEN 504 THEN 'spa'                  -- 美容/美发/按摩
    WHEN 505 THEN 'directions_run'       -- 代办/跑腿
  END
WHERE `id` IN (101, 102, 103, 201, 202, 203, 204, 301, 302, 303, 304,
               401, 402, 403, 404, 405, 501, 502, 503, 504, 505)
  AND `level` = 2;

-- -----------------------------------------------------------------------------
-- 2. 分类树版本号 bump：触发客户端重新拉取全量树（否则缓存里的旧 icon 永不过期）
-- -----------------------------------------------------------------------------
UPDATE `system_config`
SET `config_value` = '2026-10-28.1'
WHERE `config_key` = 'category_tree_version';
