-- =============================================================================
-- V4__seed_template.sql — 叶子类目发布模板种子（4 个 L2 自定义模板）
-- =============================================================================
-- 口径：模板按 L2 父级存储（template.leaf_category_id 存 L2 ID），
--   同一 L2 下所有叶子共享一份模板（对齐前端 templateForLeaf 的
--   leafCategoryId ~/ 100 逻辑）。仅 4 个 L2 有自定义模板，其余叶子走
--   通用模板兜底（TemplateService.buildGenericTemplate）。
--
-- 字段 JSON 结构对齐 openapi TemplateField schema：
--   {key, label, type, required, options?, unit?, placeholder?}
--   type ∈ {text, number, select, multi_select, date}
--
-- 模板内容逐字取自 lib/domain/publish_template.dart 的 _templatesBySecondLevel
-- （extraFields 部分）。titlePlaceholder / priceUnits / descriptionGuide 为前端
-- 本地常量，不进 template.fields（openapi Template schema 只有
-- leaf_category_id + fields 两个字段）。
-- =============================================================================

INSERT INTO `template` (`leaf_category_id`, `fields`, `template_version`) VALUES
  -- 1.1 全职招聘（L2=101）：招聘人数 / 工作时间 / 食宿情况
  (101, '[{"key":"headcount","label":"招聘人数","type":"number","required":true,"placeholder":"如：3"},{"key":"work_hours","label":"工作时间","type":"text","required":true,"placeholder":"如：10:00-22:00 单休"},{"key":"board","label":"食宿情况","type":"select","required":false,"options":["包吃包住","包吃不包住","包住不包吃","不包吃住"]}]', 1),

  -- 3.1 拼车（L2=301）：起点终点 / 出发时间 / 空座数 / 车型
  (301, '[{"key":"route","label":"起点 → 终点","type":"text","required":true,"placeholder":"如：回龙观 → 中关村"},{"key":"depart_time","label":"出发时间","type":"text","required":true,"placeholder":"如：工作日 8:00"},{"key":"seats","label":"空座数","type":"number","required":true,"placeholder":"1-6"},{"key":"car_model","label":"车型","type":"text","required":false,"placeholder":"如：轩逸（白色）"}]', 1),

  -- 4.1 二手闲置（L2=401）：新旧程度 / 取件方式
  (401, '[{"key":"condition","label":"新旧程度","type":"select","required":true,"options":["全新未拆","几乎全新","轻微使用痕迹","功能正常有磨损"]},{"key":"pickup","label":"取件方式","type":"select","required":false,"options":["仅自取","可送到楼下","可同城配送（买家付费）"]}]', 1),

  -- 5.1 家政保洁（L2=501）：可服务时间段 / 是否自带工具
  (501, '[{"key":"service_hours","label":"可服务时间段","type":"text","required":true,"placeholder":"如：工作日 9:00-18:00"},{"key":"own_tools","label":"是否自带工具","type":"select","required":false,"options":["自带全套工具与清洁剂","自带工具，清洁剂由雇主提供","不带工具"]}]', 1);
