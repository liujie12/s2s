-- =============================================================================
-- V37__post_soft_delete.sql — post 支持帖主删除（软删，2026-11-10）
-- =============================================================================
-- 出处口径：2026-11-10 用户裁定「增加删除功能」，删除语义为软删、仅非在架帖可删
--   （在架帖须先下架；草稿删除仍走客户端本地存储，不落库）。
-- 落库口径：`deleted_at` 非空即「已删除」。不新增 `status` 枚举值、不新增
--   `status_reason` 取值 —— 删除只置该列，帖子原状态（archived/hidden）保持不变；
--   对外不可见由「status 非 active」既有口径 + 读路径 `deleted_at IS NULL` 双重保证。
-- 配套改动：
--   · openapi 新增 DELETE /posts/{post_id}（query `version` 乐观锁）；
--   · PostService 删除动作 + 详情/我的发布/重发/状态变更读路径过滤；
--   · PRD §8.3.1/§8.6/§14、数据库设计 §3.5 同步。
-- 物删：本轮不做定时物理删除；保留行供举报/会话取证。
-- 回滚：先 DROP INDEX `idx_user_deleted`，再 DROP COLUMN `deleted_at`。
-- EXPLAIN：纯 DDL，无 SELECT/DML，EXPLAIN 不适用；新增索引列序
--   (user_id, deleted_at) 对齐 selectMine 的 `WHERE user_id=? AND deleted_at IS NULL`
--   前缀访问，避免「我的发布」过滤退化为回表扫描。
-- =============================================================================

ALTER TABLE `post`
    ADD COLUMN `deleted_at` DATETIME NULL
        COMMENT '软删时间（帖主删除；非空即不可见，原状态不变）'
        AFTER `updated_at`,
    ADD KEY `idx_user_deleted` (`user_id`, `deleted_at`)
        COMMENT '我的发布过滤已删除';
