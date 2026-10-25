-- =============================================================================
-- V18__pins_price_index.sql — /map/pins 覆盖索引纳入 price（语义搜索价格过滤）
-- =============================================================================
-- 出处口径：地图语音语义搜索方案 KTD3/U4
--   （docs/plans/2026-10-24-0708-feat-map-voice-semantic-search-plan.md）；
--   数据库设计文档 §4.4（idx_pins_cover 列序纪律）。
-- 口径：
--   1. 价格过滤是 `/map/pins` 的可选条件（price_min/price_max），必须与其余
--      过滤条件同处一个覆盖索引，才能维持 index-only scan 不回表。
--   2. price 列插在 expire_at（最后一个过滤列）之后、id（响应列）之前；
--      查询列集合未变，故 SELECT 列表仍全部落在索引内。
--   3. `price IS NULL`（面议）在设置上限时按 SQL 三值逻辑自然被排除，
--      这是产品口径（回执中会说明「面议未计入」），不额外加 IS NOT NULL。
--   4. 范围裁定：本迁移不建「类目专属属性」生成列。V4 模板种子只为
--      101/301/401/501 四个 L2 建了自定义模板，201 租房 L2 无模板
--      （主卧/次卧/整租本身就是 20101/20102/20103 叶子），不存在可筛的
--      select 字段，为其建生成列属过度设计（KTD3b 暂不落地）。
-- EXPLAIN 结论：待 V18 应用后以带 price_max 的 selectPins 复测，
--   目标仍为 type=range, key=idx_pins_cover, Extra="Using where; Using index"。
-- =============================================================================

ALTER TABLE `post`
  DROP INDEX `idx_pins_cover`,
  ADD KEY `idx_pins_cover`
    (`grid_id`, `leaf_category_id`, `type`, `status`, `expire_at`, `price`, `id`, `lng`, `lat`, `completeness_level`, `user_id`)
    COMMENT '/map/pins 覆盖索引（V18 起含 price）：前 6 列为过滤条件，后 5 列为响应字段，index-only scan 不回表';
