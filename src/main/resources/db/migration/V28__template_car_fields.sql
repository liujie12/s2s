-- =============================================================================
-- V28__template_car_fields.sql — 拼车模板「车辆信息」拆为 品牌 / 车型 / 颜色 / 车牌
-- =============================================================================
-- 口径（2026-10-31 用户裁定 + prototype-figma/car-brand-picker.html v3）：
--   1. 只改 L2=301（顺风车/拼车）那一行 fields：
--        · 新增 car_brand（select，必填）——候选值为常用品牌，客户端另开
--          「手动输入」兜底（手填值原样入库，不回写本表）；
--        · car_model 由 text 改 select（必填），候选值为车身形式七类；
--        · 新增 car_color（select，选填）——常用五色 + 客户端手填兜底；
--        · 新增 plate_no（text，选填）——值形态 皖A12345（单字符串），
--          三段输入（省 / 字母 / 号码）由客户端控件完成。
--      route / depart_time / seats 逐字保留，不借机改文案。
--   2. template_version 加一：客户端按版本判断本地缓存是否过期。
--   3. 本行字段与以下三处同源，任一改动须同时改：
--        · lib/domain/publish_template.dart 的 301 条目；
--        · lib/domain/car_options.dart 的候选值常量；
--        · docs/api/openapi.yaml 的 TemplateField.type 枚举（本次不新增类型）。
--   4. 历史数据：老帖 car_model 是自由文本，不清洗、不迁移；详情按原值展示。
--      car_brand / car_color / plate_no 在老帖上不存在，详情不补空行。
--   5. 不动表结构、不新增接口、不新增错误码。
-- =============================================================================

UPDATE `template`
SET `fields` = '[{"key":"route","label":"起点 → 终点","type":"route_pair","required":true,"placeholder":"如：回龙观 → 中关村"},{"key":"depart_time","label":"出发时间","type":"datetime","required":true},{"key":"seats","label":"空座数","type":"number","required":true,"placeholder":"1-6"},{"key":"car_brand","label":"品牌","type":"select","required":true,"placeholder":"选择或手填","options":["比亚迪","大众","丰田","本田","日产","吉利","长安","特斯拉","宝马","奔驰","奥迪","别克","雪佛兰","福特","现代","起亚","马自达","斯柯达","标致","雪铁龙","雷克萨斯","凯迪拉克","沃尔沃","林肯","捷豹","保时捷","长城","奇瑞","荣威","名爵","五菱","红旗","哈弗","传祺","领克","蔚来","小鹏","理想","哪吒","零跑","埃安","极氪","腾势"]},{"key":"car_model","label":"车型","type":"select","required":true,"options":["轿车","SUV","MPV","跑车","微面","皮卡","其他"]},{"key":"car_color","label":"颜色","type":"select","required":false,"placeholder":"选择或手填","options":["白色","黑色","银色","灰色","蓝色"]},{"key":"plate_no","label":"车牌","type":"text","required":false,"placeholder":"如：皖A12345"}]',
    `template_version` = `template_version` + 1
WHERE `leaf_category_id` = 301;
