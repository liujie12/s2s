-- =============================================================================
-- V22 — 资质档案字段 + 帖级凭证声明（2026-10-28）
--
-- 背景：资质取消人工审核，改为「提交即生效」，并在详情页展示证名与有效期。
--   1) cert 增加展示所需的证名、证名来源、有效期类型三列；
--   2) 帖级关联独立成表（一帖一条），携带冻结快照，不给 post 加可空字段；
--   3) 证照原件改为随资质删除，取消 7 天定时清理（原 CertImageCleanupTask 已下线）。
--
-- 依据：docs/plans/2026-10-28-1444-feat-qualification-upload-plan.md（R2/R3/R5/R6/R8/R10/R12）
--       docs/plans/2026-10-28-1344-feat-post-credential-snapshot-plan.md（R2/R3/R10）
-- 纪律：已应用的迁移不可改，本文件为新增版本。
-- =============================================================================

-- 证名与有效期来源：两列均可空，历史行不回填（空值等价于「未采集」，展示侧按无证名处理）
ALTER TABLE `cert`
  ADD COLUMN `cert_name` VARCHAR(64) NULL COMMENT '证名（OCR 读取后经用户确认，展示用）' AFTER `cert_type`,
  ADD COLUMN `name_source` ENUM('ocr','manual') NULL COMMENT '证名来源：ocr=自动读取，manual=用户手填' AFTER `cert_name`,
  ADD COLUMN `expire_type` ENUM('dated','permanent') NOT NULL DEFAULT 'dated' COMMENT '有效期类型：dated=有到期日，permanent=长期有效' AFTER `expire_at`,
  MODIFY COLUMN `ocr_image_ref` VARCHAR(128) NULL COMMENT '证照原件 OSS 引用（随资质删除时一并清理）',
  MODIFY COLUMN `expire_at` DATETIME NULL COMMENT '有效期至（expire_type=permanent 时为空）';

-- 每日任务扫描：status=approved 且 expire_at 已过 → 置 expired
ALTER TABLE `cert`
  ADD KEY `idx_status_expire` (`status`, `expire_at`) COMMENT '过期流转任务扫描';

-- -----------------------------------------------------------------------------
-- 表：post_cert_declaration — 帖级凭证声明 + 冻结快照
--
-- 为什么独立成表：补挂不能改 post 行，否则「补挂不改帖子时间」只能靠约定守住；
-- 一帖一证由 uk_post 在结构上保证（Unique 约束优先于写入守卫）。
-- 快照列只在写入时落值，之后任何换证/改名/续期都不回溯（详情页主行恒为发布时事实）。
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `post_cert_declaration`;
CREATE TABLE `post_cert_declaration` (
  `id`                    BIGINT       NOT NULL AUTO_INCREMENT      COMMENT '声明记录 ID',
  `post_id`               BIGINT       NOT NULL                     COMMENT '帖子 ID（一帖最多一条）',
  `cert_id`               BIGINT       NULL                         COMMENT '引用的 cert ID；证书被删除后保留原 ID，读取侧按记录不存在判为已删除，快照保留',
  `cert_type`             ENUM('personal_qualification','enterprise','vehicle') NOT NULL COMMENT '证件类型（快照，不含个人实名）',
  `cert_name_snapshot`    VARCHAR(64)  NOT NULL                     COMMENT '证名快照（永不改写）',
  `expire_at_snapshot`    DATETIME     NULL                         COMMENT '有效期快照；长期有效为 NULL',
  `expire_type_snapshot`  ENUM('dated','permanent') NOT NULL        COMMENT '有效期类型快照',
  `cert_status_snapshot`  ENUM('approved','expired') NOT NULL       COMMENT '关联瞬间的凭证状态；expired 表示脏数据，展示侧整块不渲染',
  `declared_at`           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '声明时间（发布时或补挂时）',
  `updated_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '行更新时间（补挂替换时刷新）',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_post` (`post_id`)                                  COMMENT '一帖一证的唯一约束',
  KEY `idx_cert` (`cert_id`)                                        COMMENT '按凭证反查被哪些帖子引用'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '帖级凭证声明—一条帖子一条记录，携带冻结快照';
