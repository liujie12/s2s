-- =============================================================================
-- V39__pins_deleted_index.sql — /map/pins 覆盖索引纳入 deleted_at（DEF-12）
-- =============================================================================
-- 出处口径：2026-11-15 处理账本 DEF-12（P3）：MapPostMapper 的 pins 聚合 / 计数 /
--   聚簇查询原先只按 status 过滤，未排除软删帖。V37 的删除语义是「只置 deleted_at，
--   原 status 不变」，故「active + 已删除」组合会被错误列出（API 路径当前不可达，
--   属防御性缺口，但直改库或放宽删除条件即暴露）。
-- 口径：
--   1. 三条查询的 WHERE 增加 `deleted_at IS NULL`（selectSearchPosts 同）。
--   2. 该条件必须落在覆盖索引内，否则 idx_pins_cover / idx_pins_community 的
--      index-only scan 退化为回表（V18 头部纪律：查询列集合不得增删）。
--   3. deleted_at 紧随 price 之后、响应列 id 之前插入；两个索引列序保持一致，
--      community 版以 community_id 为最左前缀。
-- EXPLAIN 结论：待 V39 应用后以带 price_max / community_id 的 selectPins 复测，
--   目标仍为 Extra 含 "Using index"（不回表）；库内空表时优化器可能选其它索引，
--   须用 FORCE INDEX 验证索引自身覆盖能力。
-- 回滚：DROP INDEX 后按 V19/V18 原列序重建两个索引（deleted_at 从索引中移除，
--   但列本身由 V37 定义，不得 DROP）。
-- =============================================================================

ALTER TABLE `post`
  DROP INDEX `idx_pins_cover`,
  ADD KEY `idx_pins_cover`
    (`grid_id`, `leaf_category_id`, `type`, `status`, `expire_at`, `price`, `deleted_at`, `id`, `lng`, `lat`, `completeness_level`, `user_id`)
    COMMENT '/map/pins 覆盖索引（V39 起含 deleted_at）：前 7 列为过滤条件，后 5 列为响应字段，index-only scan 不回表',
  DROP INDEX `idx_pins_community`,
  ADD KEY `idx_pins_community`
    (`community_id`, `leaf_category_id`, `type`, `status`, `expire_at`, `price`, `deleted_at`, `id`, `lng`, `lat`, `completeness_level`, `user_id`)
    COMMENT '小区精确过滤覆盖索引（V39 起含 deleted_at，过滤列在前、响应列在后，index-only 不回表）';
