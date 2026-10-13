-- =============================================================================
-- V12__temp_category.sql — 72h 临时类目快速验证通道（[153] B2-5；PRD §9.10.2）
-- =============================================================================
-- 出处口径：
--   · PRD §9.10.2「72h 临时类目快速验证通道」：运营发现新需求 → 挂「生活 → 临时 →
--     XXX」下 → **72h 自动下线** → 3 天内该类目发布数 ≥3 且被联系数 ≥5 →
--     自动进入「转正候选池」。
--   · 《决策登记表》2026-10-12（B2-5 §9.10.2 裁定）：**新建两张表** ——
--     `temp_category`（叶子级临时类目 + 生命周期）+ `temp_category_stat`（72h 判定快照）。
-- 变更：新建 2 张表，业务表数 18 → 20（见《数据库设计文档》§1.3）。
-- 设计取舍：
--   · **临时叶子仍落 `category`**：只有进分类树，C 端才能发布/检索到它。本表是其
--     「生命周期与运营归属」的扩展元数据（1:1），不是分类树的替代品。
--   · **`temp_category_stat` 是快照而非实时计数器**：计数在 72h 判定时由定时任务
--     一次性算出并存档。理由：发布/联系是 Batch1 已验收的热路径，为后台功能在热路径
--     上加写会引入耦合与失败面；快照法只在任务里读一次。
--   · **结算后置 `category.forbidden=1`**：下线 = 不再可发（而非从树里删除），
--     已发布的帖子仍需可被查看/联系，删类目会让历史帖丢归属。
-- EXPLAIN 结论：纯 DDL（CREATE TABLE），无 SELECT/DML，不适用。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

CREATE TABLE `temp_category` (
  `id`             INT          NOT NULL                          COMMENT '临时叶子类目 ID（= L2×100+序号，与 category.id 同值）',
  `l2_parent_id`   INT          NOT NULL                          COMMENT '挂载的「临时」二级类目 ID（由运营先用分类配置页建好）',
  `name`           VARCHAR(32)  NOT NULL                          COMMENT '临时类目名',
  `status`         ENUM('active','expired','promoted') NOT NULL DEFAULT 'active' COMMENT '生命周期：active=验证中 / expired=未达标已下线 / promoted=已进转正候选池',
  `created_by`     BIGINT       NOT NULL                          COMMENT '创建人（后台 admin_user.id）',
  `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `expire_at`      DATETIME     NOT NULL                          COMMENT '自动下线时刻（created_at + 72h）',
  `closed_at`      DATETIME     NULL                              COMMENT '结算时刻（任务写入）',
  PRIMARY KEY (`id`),
  KEY `idx_temp_category_status_expire` (`status`, `expire_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '72h 临时类目（PRD §9.10.2；[153] B2-5）';

CREATE TABLE `temp_category_stat` (
  `temp_category_id` INT      NOT NULL COMMENT '临时类目 ID（1:1，与 temp_category.id 同值）',
  `publish_count`    INT      NOT NULL DEFAULT 0 COMMENT '72h 窗口内发布数（判定口径：post.created_at ∈ [created_at, expire_at]）',
  `contact_count`    INT      NOT NULL DEFAULT 0 COMMENT '72h 窗口内被联系数（判定口径：该叶子下帖子的 contact_event 计数）',
  `promoted`         TINYINT  NOT NULL DEFAULT 0 COMMENT '是否达标进转正候选池（1=是；判定线见 NfrTempCategory）',
  `evaluated_at`     DATETIME NOT NULL COMMENT '判定时刻（任务写入）',
  PRIMARY KEY (`temp_category_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '临时类目 72h 判定快照（PRD §9.10.2；[153] B2-5）';
