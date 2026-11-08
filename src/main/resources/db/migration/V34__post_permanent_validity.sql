-- =============================================================================
-- V34__post_permanent_validity.sql — post 有效期支持「常驻」（2026-11-08）
-- =============================================================================
-- 出处口径：
--   · 2026-11-08 用户裁定：发布页第 7 段「有效期」增加「常驻」选项，解决资源/需求
--     需要长期提供、但不该频繁上架的问题；默认仍为 7 天。
--   · 落库口径：常驻 = `expire_at` 为 NULL。到期扫描 `expire_at <= now` 对 NULL
--     为 unknown，故常驻帖不会被 `PostExpireTask` 自动归档；发现页/地图 SQL 同步
--     改为 `(expire_at IS NULL OR expire_at > NOW())`，否则三值逻辑会把常驻帖漏掉。
-- 变更形态：`expire_at` 由 NOT NULL 改为 NULL；存量行全部有值，不涉及数据回填。
-- 配套改动：PostCreateRequest 新增 validity（7d/permanent，缺省 7d）、
--   PostService 常驻落 NULL 且 republish/renew 保持 NULL、
--   openapi PostDetail/MyPostItem/PostStatusResult 的 expire_at 标 nullable、
--   PRD §5.11 与数据库设计 §4.3 同步。
-- 回滚：重新收紧 NOT NULL 前，须先把常驻行（expire_at IS NULL）补出到期时间，
--   否则 ALTER 失败。
-- EXPLAIN 结论：纯 DDL（ALTER TABLE MODIFY），无 SELECT/DML，EXPLAIN 不适用。
--   索引 idx_pins_cover / idx_status_expire 均含 expire_at，NULL 在 MySQL 索引中
--   有序排列，`IS NULL OR > NOW()` 仍可走 range 访问；常驻占比低时不影响覆盖扫描。
-- =============================================================================

ALTER TABLE `post`
    MODIFY COLUMN `expire_at` DATETIME NULL
        COMMENT '到期时间（默认 +7 天；NULL=常驻，不自动下架）';
