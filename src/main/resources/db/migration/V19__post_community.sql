-- =============================================================================
-- V19__post_community.sql — 小区实体归一（口语地址精确过滤）
-- =============================================================================
-- 出处口径：地图语音语义搜索「地址/小区匹配」修订（用户 2026-10-24 裁定）。
-- 口径：
--   1. 用户在口语里说「北城新徽苑」时，要精确排除其他小区；靠 `community_id`
--      等值过滤，而不是文本 LIKE 或向量相似度。ID 取高德住宅区 POI ID（字符串）。
--   2. 发布时解析并落库；解析失败允许为空（搜索走「半径 + 地址」近似回退）。
--   3. 老帖子无 community_id，需后续回填；未回填前只能走近似回退。
--   4. 复合索引列序：community_id 等值 → 其余过滤条件 → 响应列，
--      保持 `/map/pins` index-only scan（不回表）。
-- EXPLAIN 结论：待 V19 应用后以 `community_id = ?` 的 selectPins 复测，
--   目标 type=ref, key=idx_pins_community, Extra="Using where; Using index"。
-- =============================================================================

ALTER TABLE `post`
  ADD COLUMN `community_id`   VARCHAR(64) NULL COMMENT '小区实体 ID（高德住宅区 POI ID；发布时解析，可空）' AFTER `address`,
  ADD COLUMN `community_name` VARCHAR(64) NULL COMMENT '小区规范名（用于回显；可空）' AFTER `community_id`,
  ADD KEY `idx_pins_community`
    (`community_id`, `leaf_category_id`, `type`, `status`, `expire_at`, `price`, `id`, `lng`, `lat`, `completeness_level`, `user_id`)
    COMMENT '小区精确过滤覆盖索引（过滤列在前、响应列在后，index-only 不回表）';
