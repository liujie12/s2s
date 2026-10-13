-- =============================================================================
-- V11__ops_follow_up.sql — 待运营跟进队列（[153] B2-5 ⑥）
-- =============================================================================
-- 出处口径：
--   · PRD §6.4.4「动态蜂窝半径引擎（S2）」：**空圈且 30 秒内三级兜底均无结果 →
--     该需求进「待运营跟进队列」（后台队列）**。
--   · 《决策登记表》2026-10-12（B2-5 ⑥ 裁定）：① **新建独立表 `ops_follow_up`**
--     （原 16+1 张表均无该队列载体，禁自创口径前须先裁定）；② **入队触发 = 搜索
--     空结果时写**（`/posts/search` 返回 total=0 即入队，与 §6.4.4 触发条件等价）。
-- 变更：新建 `ops_follow_up`，业务表数 17 → 18（见《数据库设计文档》§1.3）。
-- 设计取舍：
--   · **不存精确经纬度**：只存粗粒度 `grid_id`（约 500m 网格）。队列用途是「找到
--     哪片区域缺供给」，精确坐标对运营无用却会扩大位置个人信息面（编码规范 §4.11）。
--   · **不建唯一键去重**：`user_id`/`keyword` 可空，而 MySQL 唯一索引对 NULL 不去重
--     （同一游客可无限重复入队）；去重口径移入 service（「同 user+keyword+l2 已有
--     pending 则跳过」），使口径显式可读、可测。
-- EXPLAIN 结论：纯 DDL（CREATE TABLE），无 SELECT/DML，不适用。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

CREATE TABLE `ops_follow_up` (
  `id`             BIGINT       NOT NULL AUTO_INCREMENT          COMMENT '队列条目 ID',
  `user_id`        BIGINT       NULL                            COMMENT '触发检索的用户（游客为空）',
  `keyword`        VARCHAR(64)  NULL                            COMMENT '检索关键词（可空＝纯类目检索）',
  `l2_category_id` INT          NULL                            COMMENT '检索的二级类目 ID（取入口 category_ids 首个；可空）',
  `grid_id`        VARCHAR(32)  NULL                            COMMENT '坐标网格（约 500m，粗粒度；不存精确经纬度）',
  `status`         ENUM('pending','handled') NOT NULL DEFAULT 'pending' COMMENT '处理状态',
  `handler_id`     BIGINT       NULL                            COMMENT '处理人（后台 admin_user.id）',
  `handled_at`     DATETIME     NULL                            COMMENT '处理时间',
  `remark`         VARCHAR(255) NULL                            COMMENT '处理备注',
  `triggered_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '入队时间',
  PRIMARY KEY (`id`),
  KEY `idx_ops_follow_up_status_time` (`status`, `triggered_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '待运营跟进队列（[153] B2-5 ⑥；PRD §6.4.4 空圈触发）';
