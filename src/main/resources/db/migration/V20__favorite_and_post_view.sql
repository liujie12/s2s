-- -----------------------------------------------------------------------------
-- 收藏 + 浏览计数（2026-10-27）
--
-- 1) favorite 增按帖聚合索引：帖主计数查询走 (post_id, deleted_at)。
-- 2) post_view：浏览明细，唯一键承担「人/天」去重；保留 30 天后由
--    PostViewCleanupTask 分批删除。
-- 3) post_view_daily：浏览日计数，写入即结算；永久保留，保证浏览数单调不降。
--
-- 不修改任何已应用迁移（V1 为历史快照）。
-- -----------------------------------------------------------------------------

ALTER TABLE `favorite`
  ADD KEY `idx_post_deleted` (`post_id`, `deleted_at`) COMMENT '帖主收藏数聚合：按帖 + 软删过滤';

DROP TABLE IF EXISTS `post_view`;
CREATE TABLE `post_view` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '浏览明细 ID',
  `post_id`             BIGINT       NOT NULL                        COMMENT '被浏览帖子 ID',
  `viewer_key`          VARCHAR(64)  NOT NULL                        COMMENT '去重键：user:<id> 或 device:<uuid>',
  `view_day`            DATE         NOT NULL                        COMMENT '业务日（Asia/Shanghai）',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '首次记录时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_post_viewer_day` (`post_id`, `viewer_key`, `view_day`) COMMENT '同一帖子同一 viewer 同一业务日只计 1 次',
  KEY `idx_view_day` (`view_day`)                                    COMMENT '保留期清理扫描'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '浏览明细—人/天去重，保留 30 天后清理；计数真源是 post_view_daily';

DROP TABLE IF EXISTS `post_view_daily`;
CREATE TABLE `post_view_daily` (
  `post_id`             BIGINT       NOT NULL                        COMMENT '帖子 ID',
  `view_day`            DATE         NOT NULL                        COMMENT '业务日（Asia/Shanghai）',
  `view_count`          INT UNSIGNED NOT NULL DEFAULT 0              COMMENT '当日去重浏览数',
  PRIMARY KEY (`post_id`, `view_day`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '浏览日计数—永久保留，帖主浏览数 = 按帖 SUM(view_count)';
