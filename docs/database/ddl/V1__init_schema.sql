-- =============================================================================
-- s2s 二手交易 App — Batch1 首版 schema
-- =============================================================================
-- 适用 MySQL 8.4 LTS，Flyway 命名 V1__init_schema.sql
-- 字符集 utf8mb4 + utf8mb4_0900_ai_ci，引擎 InnoDB
-- 表/字段 COMMENT 均为中文，符合用户规则 5.2
-- 不写外键约束：读路径信任冗余列、写路径由 service 层同事务维护（架构 §5.1.1）
-- 生成列用 STORED：可建索引、可被 WHERE 命中
-- 敏感字段盲索引双列：identity_hash/identity_value_enc + key_version
-- 依据：docs/PRD.md §13、docs/architecture/系统总体架构设计文档.md §5、
--      docs/plans/2026-09-04-1630-refactor-batch1-data-model-corrections-plan.md
--
-- 执行方式（Batch1 现状）：由 docker-entrypoint-initdb.d 在容器首次启动时执行，
--   MySQL entrypoint 会先创建 MYSQL_DATABASE 指定的库并切入其中，故本脚本
--   【不写】USE 语句 —— 写死库名会与 .env 中的 MYSQL_DATABASE 脱耦。
--   编码期引入 Flyway 后改由 Flyway datasource 执行，届时本注释作废。
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- =============================================================================
-- 域：auth
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：user — 用户账号
-- PRD §13.2 字段字典；R2 落地：phone→phone_mask 脱敏掩码
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `user`;
CREATE TABLE `user` (
  `id`                    BIGINT       NOT NULL AUTO_INCREMENT       COMMENT '用户 ID',
  `phone_mask`            VARCHAR(20)  NOT NULL                      COMMENT '手机号脱敏掩码（138****8000），仅展示；原文落 user_identity 走盲索引',
  `nickname`              VARCHAR(32)  NOT NULL                      COMMENT '昵称',
  `avatar_url`            VARCHAR(256) NULL                          COMMENT '头像 OSS URL',
  `realname_status`       ENUM('none','pending','passed','rejected') NOT NULL DEFAULT 'none' COMMENT '实名状态',
  `real_name_enc`         VARBINARY(255) NULL                        COMMENT '姓名 AEAD 密文（仅解密展示）',
  `id_card_hash`          BINARY(32)   NULL                          COMMENT '身份证号 HMAC-SHA256+pepper 32 字节，不可逆',
  `id_card_last4`         CHAR(4)      NULL                          COMMENT '身份证后 4 位明文（用户自查与客服核对）',
  `default_radius`        ENUM('1','3','5','10','city') NOT NULL DEFAULT '3' COMMENT '默认搜索半径档',
  `deactivate_at`         DATETIME     NULL                          COMMENT '注销发起时间，+7 天冷静期',
  `key_version`           TINYINT      NOT NULL DEFAULT 0            COMMENT '加解密所用密钥版本号（支持灰度轮换）',
  `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_id_card_hash` (`id_card_hash`)
    COMMENT '实名去重：一证一号。承载 HMAC 确定性列的等值查询（盲索引范式，见数据库设计文档 §7.1）；未实名用户该列为 NULL，MySQL 唯一索引允许多个 NULL 故不冲突',
  KEY `idx_realname_status` (`realname_status`),
  KEY `idx_deactivate_at` (`deactivate_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '用户账号—手机号原文落 user_identity 走盲索引，本表只展示掩码';

-- -----------------------------------------------------------------------------
-- 表：user_identity — 登录身份归一化映射（phone/wechat/apple）
-- PRD §13.2；R1 落地：盲索引双列 identity_hash + identity_value_enc
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `user_identity`;
CREATE TABLE `user_identity` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '身份行 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '指向 user.id；多条身份共用同一 user_id 即同一自然人',
  `identity_type`       ENUM('phone','wechat','apple') NOT NULL     COMMENT '身份类型；Batch1 只写 phone，wechat/apple 于 Batch2 打开',
  `identity_hash`       BINARY(32)   NOT NULL                        COMMENT 'HMAC-SHA256+pepper 32 字节，承载唯一索引与等值查询',
  `identity_value_enc`  VARBINARY(255) NOT NULL                      COMMENT 'AEAD 密文（随机 IV），仅用于解密展示',
  `key_version`         TINYINT      NOT NULL                        COMMENT '加解密所用密钥版本号',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '绑定时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_type_hash` (`identity_type`, `identity_hash`)       COMMENT '同一身份值不可绑两个账号',
  UNIQUE KEY `uk_user_type` (`user_id`, `identity_type`)             COMMENT '一个账号在每种身份上至多一条',
  KEY `idx_user_id` (`user_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '登录身份归一化—盲索引双列范式，注销按 user_id 删全部行';

-- =============================================================================
-- 域：category
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：category — 三级分类树
-- PRD §13.2；R12 落地：version 列移出至 system_config
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `category`;
CREATE TABLE `category` (
  `id`                  INT          NOT NULL                        COMMENT '分类 ID（三级编号即不变量，已发布不得重排）',
  `parent_id`           INT          NULL                            COMMENT '父分类 ID；顶级为 NULL',
  `level`               TINYINT      NOT NULL                        COMMENT '层级 1=大类/2=二级/3=叶子',
  `name`                VARCHAR(32)  NOT NULL                        COMMENT '分类名',
  `color`               VARCHAR(32)  NULL                            COMMENT '大类色，按 PRD §1.4.3 Token 键取值（如 cat-vehicle）',
  `icon`                VARCHAR(64)  NULL                            COMMENT 'Material Symbols 图标名',
  `need_cert`           VARCHAR(32)  NULL                            COMMENT '非空即高敏类目，发布前强制认证类型',
  `forbidden`           TINYINT      NOT NULL DEFAULT 0              COMMENT '禁发类目标记（运营可配）',
  `cluster_threshold`   TINYINT      NOT NULL DEFAULT 8              COMMENT '差异化聚合阈值（工作 3 / 房屋 5 / 生活 8 / 车辆·服务 8）',
  `sort_order`          INT          NOT NULL DEFAULT 0              COMMENT '同级排序',
  PRIMARY KEY (`id`),
  KEY `idx_parent_id` (`parent_id`),
  KEY `idx_level_sort` (`level`, `sort_order`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '三级分类树—全局版本号在 system_config 表';

-- -----------------------------------------------------------------------------
-- 表：template — 叶子类目发布模板 Schema
-- PRD §13.2（R19 新造字段）
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `template`;
CREATE TABLE `template` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '模板 ID',
  `leaf_category_id`    INT          NOT NULL                        COMMENT '叶子类目 ID（与 category 表 1:1）',
  `fields`              JSON         NOT NULL                        COMMENT '动态表单 Schema（字段定义、校验规则、价格单位等）',
  `template_version`    INT          NOT NULL                        COMMENT '模板版本号，与 post.template_version 对齐',
  `updated_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '模板更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_leaf_category_id` (`leaf_category_id`)             COMMENT '叶子类目 1:1 模板'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '叶子类目发布模板 Schema';

-- -----------------------------------------------------------------------------
-- 表：system_config — 系统级 key-value 配置（R12 落地，R27）
-- 承载分类树全局版本号与其他系统级配置
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `system_config`;
CREATE TABLE `system_config` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '配置项 ID',
  `config_key`          VARCHAR(64)  NOT NULL                        COMMENT '配置键（如 category_tree_version）',
  `config_value`        TEXT         NOT NULL                        COMMENT '配置值',
  `description`         VARCHAR(256) NULL                            COMMENT '配置说明',
  `updated_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  `version`             INT          NOT NULL DEFAULT 0              COMMENT '乐观锁版本号',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_config_key` (`config_key`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '系统级 key-value 配置—承载分类树版本号等';

-- 初始数据：分类树全局版本号 + 详情额度开关
-- 版本号格式为 YYYY-MM-DD.N 字符串（架构 §9.2.1 唯一口径，对齐
-- lib/domain/category_tree.dart:23 的 '2026-08-31.1'）。运营改配置时：
-- 同日再改递增 N，跨日则重置为当日日期 .1。字符串比较即可判新旧。
-- 2026-09-06 详细设计阶段裁定：原写整数 '1' 与架构冲突，以架构为准改为字符串。
INSERT INTO `system_config` (`config_key`, `config_value`, `description`, `version`)
VALUES ('category_tree_version', '2026-08-31.1', '分类树全局版本号，格式 YYYY-MM-DD.N；运营改配置时同日递增 N、跨日重置为当日.1', 0);

-- 未实名详情浏览额度开关（PRD §12.3 每日 3 条 / 第 4 条回 40301）。
-- 2026-09-06 详细设计阶段裁定：Batch1 的 cert 域整体延后，全员
-- realname_status='none'，额度生效会把「地图→详情→联系」五大 P0 闭环卡死
-- （每人每天只能看 3 条详情）。故服务端代码路径完整实现、由本开关控制，
-- Batch1 置 off；Batch2 实名功能上线时同步置 on。
INSERT INTO `system_config` (`config_key`, `config_value`, `description`, `version`)
VALUES ('detail_quota_enabled', 'off', '未实名详情浏览额度开关 on/off；Batch1 为 off，随 Batch2 实名上线置 on', 0);

-- =============================================================================
-- 域：post
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：post — 发布信息（资源/需求同表，type 区分）
-- PRD §13.2；R6/R7/R9/R10/R11 落地
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `post`;
CREATE TABLE `post` (
  `id`                      BIGINT       NOT NULL AUTO_INCREMENT     COMMENT '帖子 ID',
  `user_id`                 BIGINT       NOT NULL                    COMMENT '发布者 user_id',
  `type`                    ENUM('resource','demand') NOT NULL       COMMENT '类型：resource 资源/demand 需求',
  `leaf_category_id`        INT          NOT NULL                    COMMENT '叶子类目 ID（驱动模板与详情渲染）',
  `l2_category_id`          INT          GENERATED ALWAYS AS (`leaf_category_id` DIV 100) STORED COMMENT '二级类目 ID（STORED 生成列，Hard Filter 用，不可写）',
  `title`                   VARCHAR(64)  NOT NULL                    COMMENT '标题（过敏感词双重校验）',
  `desc`                    TEXT         NOT NULL                    COMMENT '描述正文（过敏感词双重校验）',
  `grid_id`                 VARCHAR(24)  NOT NULL                    COMMENT '约 500m 网格 ID 字符串 gx_gy，整数微度域计算，服务端与客户端逐位一致',
  `price`                   DECIMAL(12,2) NULL                       COMMENT '价格（NULL 表示面议）',
  `price_unit`              VARCHAR(16)  NULL                        COMMENT '价格单位（取模板 price_units 之一）',
  `lng`                     DECIMAL(10,6) NOT NULL                   COMMENT 'GCJ-02 经度（仅发布点不存轨迹）',
  `lat`                     DECIMAL(10,6) NOT NULL                   COMMENT 'GCJ-02 纬度（仅发布点不存轨迹）',
  `address`                 VARCHAR(128) NULL                        COMMENT '门牌号地址（影响完整度档）',
  `template_values`         JSON         NULL                        COMMENT '模板字段实际值',
  `contact_channel`         ENUM('phone','wechat') NOT NULL         COMMENT '联系方式渠道（二选一单轨）',
  `contact_value_enc`       VARBINARY(255) NOT NULL                  COMMENT '联系方式 AEAD 密文（仅 /contact 接口解密返回）',
  `completeness_conditions` JSON         NOT NULL                    COMMENT '三条件达成态 {required_full, address_precise, leaf_matched}',
  `completeness_level`      TINYINT      GENERATED ALWAYS AS (
    CASE
      WHEN (IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.required_full')) = 'true', 1, 0)
          + IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.address_precise')) = 'true', 1, 0)
          + IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.leaf_matched')) = 'true', 1, 0)) = 3 THEN 2
      WHEN (IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.required_full')) = 'true', 1, 0)
          + IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.address_precise')) = 'true', 1, 0)
          + IF(JSON_UNQUOTE(JSON_EXTRACT(`completeness_conditions`, '$.leaf_matched')) = 'true', 1, 0)) = 2 THEN 1
      ELSE 0
    END
  ) STORED                                COMMENT '完整度档位 0=红/1=黄/2=绿（STORED 生成列，由三条件达成计数派生）',
  `restricted`              TINYINT      NOT NULL DEFAULT 0          COMMENT '未实名先发后审受限态',
  `status`                  ENUM('draft','active','archived','hidden') NOT NULL DEFAULT 'draft' COMMENT '状态机：draft/active/archived/hidden',
  `status_reason`           TINYINT      NULL                        COMMENT '进入非 active 路径：0=用户主动下架/1=到期自动下架/2=审核下架/3=成交',
  `status_changed_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'status 变更时刻（PRD §6.12 客观行为代理档位依赖）',
  `template_version`        INT          NOT NULL                    COMMENT '发布时模板版本号（模板改版不改变已发布帖语义）',
  `risk_score`              SMALLINT     NOT NULL DEFAULT 0          COMMENT '风险分累计，≥60 自动下架',
  `expire_at`               DATETIME     NOT NULL                    COMMENT '到期时间（默认 +7 天；连续 14 天未刷新自动 archived）',
  `version`                 BIGINT       NOT NULL DEFAULT 0          COMMENT '乐观锁版本号（架构 §5.2，@Version）',
  `key_version`             TINYINT      NOT NULL                    COMMENT '联系方式 AEAD 密钥版本号',
  `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`),
  KEY `idx_pins_cover` (`grid_id`, `leaf_category_id`, `type`, `status`, `expire_at`, `id`, `lng`, `lat`, `completeness_level`, `user_id`)
    COMMENT '/map/pins 覆盖索引：前 5 列为过滤条件，后 5 列为响应字段（PRD §6.10 pins[] schema 的 id/lng/lat/category_id/type/completeness_level 六项已全在索引内），达成 index-only scan 不回表；user_id 供归属判定。列序由 EXPLAIN 实测定',
  KEY `idx_user_status_created` (`user_id`, `status`, `created_at`) COMMENT '我的发布筛选',
  KEY `idx_status_expire` (`status`, `expire_at`)                   COMMENT '到期自动下架扫描',
  KEY `idx_l2_type_status` (`l2_category_id`, `type`, `status`, `expire_at`) COMMENT 'Hard Filter 候选索引（Batch2 启用）',
  KEY `idx_status_completeness` (`status`, `completeness_level`, `created_at`) COMMENT '列表完整度排序'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '发布信息—资源/需求同表，含状态归因与生成列';

-- -----------------------------------------------------------------------------
-- 表：post_media — 帖子媒体（OSS 两步直传登记）
-- PRD §13.2（R20 新造字段）；表名沿用 PRD 不用架构 §5.1 的 media
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `post_media`;
CREATE TABLE `post_media` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '媒体 ID',
  `post_id`             BIGINT       NULL                            COMMENT '关联 post.id；未关联时为孤儿 media（编辑态）',
  `object_key`          VARCHAR(128) NOT NULL                        COMMENT 'OSS 对象键',
  `audit_status`        ENUM('pending','pass','reject') NOT NULL DEFAULT 'pending' COMMENT '内容审核状态',
  `reject_reason`       VARCHAR(64)  NULL                            COMMENT '审核拒绝原因',
  `content_type`        VARCHAR(32)  NOT NULL                        COMMENT 'MIME 类型',
  `size_bytes`          INT          NOT NULL                        COMMENT '文件字节数',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`id`),
  KEY `idx_post_id_audit` (`post_id`, `audit_status`),
  KEY `idx_audit_status_created` (`audit_status`, `created_at`)      COMMENT '孤儿 media 清理扫描'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '帖子媒体—OSS 直传登记，audit_status!=pass 不出现在非本人响应';

-- -----------------------------------------------------------------------------
-- 表：publish_memory — 发布记忆（180 天保留）
-- PRD §13.2；Batch2 建表
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `publish_memory`;
CREATE TABLE `publish_memory` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '记忆 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '用户 ID',
  `leaf_category_id`    INT          NOT NULL                        COMMENT '叶子类目 ID',
  `values`              JSON         NOT NULL                        COMMENT '最近一次填写值',
  `saved_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '保存时间（>30 天提示，>180 天清空）',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_user_leaf` (`user_id`, `leaf_category_id`)          COMMENT '记忆维度复合唯一键'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '发布记忆—180 天保留，按 user_id+leaf_category_id 去重';

-- =============================================================================
-- 域：contact
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：contact_event — 联系事件（北极星辅助指标唯一统计点）
-- PRD §13.2；红线：禁增 contacted_success/deal_done 等成交反馈字段
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `contact_event`;
CREATE TABLE `contact_event` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '事件 ID',
  `post_id`             BIGINT       NOT NULL                        COMMENT '帖子 ID',
  `from_user_id`        BIGINT       NOT NULL                        COMMENT '发起联系者 user_id',
  `to_user_id`          BIGINT       NOT NULL                        COMMENT '被联系发布者 user_id',
  `channel_type`        ENUM('phone','wechat') NOT NULL             COMMENT '联系方式渠道',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '联系时刻（北极星窗口判定用）',
  PRIMARY KEY (`id`),
  KEY `idx_from_user_created` (`from_user_id`, `created_at`)         COMMENT '联系限频判定（账号维）',
  KEY `idx_post_id_created` (`post_id`, `created_at`)                COMMENT '按帖查联系事件'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '联系事件—只记动作是否发生，禁成交反馈字段';

-- -----------------------------------------------------------------------------
-- 表：report — 举报与风险分
-- PRD §13.2；R26 落地：补齐 reported_user_id/evidence/status/handled_at/handler_id
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `report`;
CREATE TABLE `report` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '举报 ID',
  `post_id`             BIGINT       NOT NULL                        COMMENT '被举报帖子 ID',
  `reporter_id`         BIGINT       NOT NULL                        COMMENT '举报者 user_id',
  `reported_user_id`    BIGINT       NOT NULL                        COMMENT '被举报发布者 user_id（按用户查举报历史）',
  `reason`              ENUM('false_info','fraud','wrong_category','harassment','other') NOT NULL COMMENT '举报原因',
  `description`         VARCHAR(512) NULL                            COMMENT '举报描述',
  `evidence`            JSON         NULL                            COMMENT '举报凭证 media_ids 数组',
  `weight`              TINYINT      NOT NULL DEFAULT 0              COMMENT '风险分权重（运营可配）',
  `is_false_report`     TINYINT      NOT NULL DEFAULT 0              COMMENT '运营打标误报，不计入累计风险分',
  `status`              ENUM('pending','handled','dismissed') NOT NULL DEFAULT 'pending' COMMENT '处理状态',
  `handler_id`          BIGINT       NULL                            COMMENT '处理人 user_id',
  `handled_at`          DATETIME     NULL                            COMMENT '处理时间',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '举报时间',
  PRIMARY KEY (`id`),
  KEY `idx_post_status_created` (`post_id`, `status`, `created_at`),
  KEY `idx_reported_user_status` (`reported_user_id`, `status`, `created_at`),
  KEY `idx_reporter_created` (`reporter_id`, `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '举报—含凭证与处理状态，weight 累计入 post.risk_score';

-- -----------------------------------------------------------------------------
-- 表：favorite — 收藏
-- PRD §13.2（R24 新造字段）；Batch2 建表；按 post_id 去重，30 天软删后物删
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `favorite`;
CREATE TABLE `favorite` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '收藏 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '收藏者 user_id',
  `post_id`             BIGINT       NOT NULL                        COMMENT '被收藏帖子 ID',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '收藏时间',
  `deleted_at`          DATETIME     NULL                            COMMENT '软删时间（30 天后物删）',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_user_post` (`user_id`, `post_id`)                    COMMENT '一对 user-post 全生命周期只有一行，重新收藏走 ON DUPLICATE KEY UPDATE 复活',
  KEY `idx_user_deleted` (`user_id`, `deleted_at`)                    COMMENT '按用户查收藏列表 + 软删过滤',
  KEY `idx_deleted_at` (`deleted_at`)                                COMMENT '30 天物删扫描'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '收藏—软删 30 天后物删，唯一性由物理唯一索引 uk_user_post 保证（非 service 层查重）';

-- =============================================================================
-- 域：cert
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：cert — 实名与资质认证记录
-- PRD §13.2（R25 新造字段）；Batch2 建表；四类认证，三态状态，人工审核 SLA≤2h
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `cert`;
CREATE TABLE `cert` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '认证 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '申请人 user_id',
  `cert_type`           ENUM('personal_realname','personal_qualification','enterprise','vehicle') NOT NULL COMMENT '认证类型',
  `status`              ENUM('pending','approved','rejected','expired') NOT NULL DEFAULT 'pending' COMMENT '认证状态',
  `submitted_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '提交时间',
  `approved_at`         DATETIME     NULL                            COMMENT '审核通过时间',
  `expire_at`           DATETIME     NULL                            COMMENT '认证到期时间',
  `reject_reason`       VARCHAR(256) NULL                            COMMENT '审核拒绝原因',
  `ocr_image_ref`       VARCHAR(128) NULL                            COMMENT 'OCR 原始证照图 OSS 引用（7 天后清理）',
  `fail_count`          TINYINT      NOT NULL DEFAULT 0              COMMENT '该用户该类型认证失败次数',
  `lock_until`          DATETIME     NULL                            COMMENT '锁定到（防刷）',
  PRIMARY KEY (`id`),
  KEY `idx_user_type_status` (`user_id`, `cert_type`, `status`),
  KEY `idx_status_submitted` (`status`, `submitted_at`)              COMMENT '审核工作台扫描'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '认证记录—user 存最新聚合态，cert 存每次申请';

-- =============================================================================
-- 域：notify
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：notification — 站内通知（三 Tab：系统/互动/认证）
-- PRD §13.2（R22 新造字段）
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `notification`;
CREATE TABLE `notification` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '通知 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '接收者 user_id',
  `type`                ENUM('system','interaction','cert') NOT NULL COMMENT '通知类型（对应三 Tab）',
  `title`               VARCHAR(64)  NOT NULL                        COMMENT '通知标题',
  `summary`             VARCHAR(256) NULL                            COMMENT '通知摘要',
  `target_id`           BIGINT       NULL                            COMMENT '关联对象 ID（post/report/cert 等）',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `read_at`             DATETIME     NULL                            COMMENT '已读时间',
  `deleted_at`          DATETIME     NULL                            COMMENT '软删时间',
  PRIMARY KEY (`id`),
  KEY `idx_user_type_deleted_created` (`user_id`, `type`, `deleted_at`, `created_at`) COMMENT '按 Tab 拉取通知列表'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '站内通知—三 Tab 按 type 分流，软删支持';

-- -----------------------------------------------------------------------------
-- 表：device — 推送 token 与设备指纹
-- PRD §13.2（R21 新造字段）；双重职责：限频 + 推送
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `device`;
CREATE TABLE `device` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '设备 ID',
  `user_id`             BIGINT       NOT NULL                        COMMENT '所属 user_id',
  `fingerprint`         VARCHAR(64)  NOT NULL                        COMMENT '设备指纹（UUID，限频键，重装即变）',
  `platform`            ENUM('android','ios') NOT NULL               COMMENT '平台',
  `push_token`          VARCHAR(128) NULL                            COMMENT '推送 token（FCM/APNs）',
  `last_active_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '最后活跃时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_fingerprint` (`fingerprint`)                        COMMENT '设备指纹唯一（联系限频的设备维）',
  KEY `idx_user_id` (`user_id`),
  KEY `idx_last_active_at` (`last_active_at`)                        COMMENT '不活跃设备清理'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '设备—指纹做限频、push_token 做推送，重装即新指纹';

-- =============================================================================
-- 域：common
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：audit_log — 运营操作留痕（≥180 天保留）
-- PRD §13.2（R23 新造字段）；§9.10.1 已定义 7 项审计字段口径
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `audit_log`;
CREATE TABLE `audit_log` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '审计 ID',
  `operator_id`         BIGINT       NOT NULL                        COMMENT '操作人 user_id',
  `operator_role`       ENUM('super_admin','admin','auditor','system') NOT NULL COMMENT '操作人角色',
  `action`              VARCHAR(64)  NOT NULL                        COMMENT '动作（如 post.archive、user.deactivate）',
  `target_type`         VARCHAR(32)  NOT NULL                        COMMENT '目标对象类型（post/user/cert 等）',
  `target_id`           BIGINT       NOT NULL                        COMMENT '目标对象 ID',
  `before_value`        JSON         NULL                            COMMENT '变更前值',
  `after_value`         JSON         NULL                            COMMENT '变更后值',
  `reason`              VARCHAR(256) NULL                            COMMENT '操作理由',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '操作时间',
  PRIMARY KEY (`id`),
  KEY `idx_operator_created` (`operator_id`, `created_at`)           COMMENT '按操作人查',
  KEY `idx_target_created` (`target_type`, `target_id`, `created_at`) COMMENT '按目标对象查'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '审计留痕—≥180 天保留，仅超级管理员可查';

SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- 埋点表不在本脚本内
-- 架构 R14：埋点数据落与业务数据独立的 database（同一 MySQL 实例）。
-- track_event_YYYYMM 月表与 track_event_fallback 兜底表见同目录
-- V1__init_track_schema.sql，由独立的 Flyway datasource 执行。
-- =============================================================================
