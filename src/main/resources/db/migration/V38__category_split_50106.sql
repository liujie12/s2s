-- =============================================================================
-- V38__category_split_50106.sql — 50106「保姆/月嫂/钟点工」拆成 50107/50108/50109
-- =============================================================================
-- 为什么是 V38 而不是 V37：V37 已被 `V37__post_soft_delete.sql`（2026-11-10 帖主软删）
--   占用。两个文件同时叫 V37 时 Flyway 启动即报
--   `Found more than one migration with version 37`，整个应用起不来。
--   2026-11-12 发现并纠正：按时间顺序，11-10 的软删保持 V37，11-11 的拆分顺延 V38。
--
-- 出处口径：2026-11-11 图标定稿（prototype-figma/level3-icon-exploration.html）
--   把原先合成的一个叶子拆成三个独立服务：保姆 / 月嫂 / 钟点工。
--   三者工作内容、定价与资质不同，合并成一个叶子会让发布者选不准、搜索也打不准。
--
-- 编号纪律（沿用 V35）：只追加、不重排。50106 不再复用，新叶子顺延 50107–50109；
--   已有帖子指向 50106 的一律迁到 50107（保姆），这是最接近原「保姆/月嫂/钟点工」
--   首选项的归类，迁移后可由发布者自行编辑改选。
--
-- 幂等：本脚本允许重复执行。线上若先手工灌库（不重启应用、Flyway 未参与），
--   之后发版时 Flyway 会把本文件再执行一次；非幂等的写法（重复主键、重复同义词）
--   会让那次发版失败，故所有写操作都写成可重放形式。
--
-- 依赖：V35 已建 501 下 50101–50106；V36 已为 50106 灌同义词。
-- 纯数据变更，无 DDL。
-- =============================================================================

-- 1. 新增三个叶子（icon 取自图标定稿：看护 / 孕产照护 / 计时）；重复执行时按现值覆盖
INSERT INTO `category` (`id`, `parent_id`, `level`, `name`, `need_cert`, `sort_order`, `icon`) VALUES
  (50107, 501, 3, '保姆',   'personal_qualification', 6, 'escalator_warning'),
  (50108, 501, 3, '月嫂',   'personal_qualification', 7, 'pregnant_woman'),
  (50109, 501, 3, '钟点工', 'personal_qualification', 8, 'av_timer')
ON DUPLICATE KEY UPDATE
  `parent_id`  = VALUES(`parent_id`),
  `level`      = VALUES(`level`),
  `name`       = VALUES(`name`),
  `need_cert`  = VALUES(`need_cert`),
  `sort_order` = VALUES(`sort_order`),
  `icon`       = VALUES(`icon`);

-- 2. 存量帖子迁移：50106 → 50107（保姆）
--    先迁再删，避免外键约束失败；已迁移过时本句命中 0 行，可重放。
UPDATE `post` SET `leaf_category_id` = 50107 WHERE `leaf_category_id` = 50106;

-- 3. 先清同义词再删类目行（同义词后置插入，保证重复执行不会累积）
--    连带清掉 50107–50109：手工灌库后 Flyway 再跑一次时，避免同义词翻倍。
DELETE FROM `category_synonym` WHERE `leaf_category_id` IN (50106, 50107, 50108, 50109);
DELETE FROM `category` WHERE `id` = 50106;

-- 4. 三个新叶子的同义词（原名 100 / 常用别名 90–95 / 泛化词 80–85，沿用 V17/V36 口径）
INSERT INTO `category_synonym` (`term`, `pinyin`, `leaf_category_id`, `weight`) VALUES
  ('保姆',       'bm',    50107, 100), ('住家保姆', 'zjbm', 50107, 90), ('育儿嫂', 'yes', 50107, 85),
  ('月嫂',       'ys',    50108, 100), ('产后护理', 'chhl', 50108, 85), ('月子护理', 'yzhl', 50108, 85),
  ('钟点工',     'zdg',   50109, 100), ('小时工',   'xsg',  50109, 90), ('保洁钟点工', 'bjzdg', 50109, 85);

-- 5. 分类树版本号 bump：不 bump 则服务端回 data=null，已有缓存客户端看不到新树
UPDATE `system_config`
SET `config_value` = '2026-11-11.1'
WHERE `config_key` = 'category_tree_version';
