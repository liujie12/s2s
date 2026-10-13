-- =============================================================================
-- V13__admin_cert_access_request.sql — 认证原始信息「敏感查看双人复核」申请（[153] B2-5；PRD §9.10.1）
-- =============================================================================
-- 出处口径：
--   · PRD §9.10.1「敏感查看双人复核：查看身份证后 4 位以外的任何认证原始信息，
--     需另一名管理员在后台确认后方可打开（配合 §4.7 只存哈希的口径）」。
--   · 《决策登记表》2026-10-12（B2-5 §9.10.1 裁定）：**新建复核申请表**，
--     复核对象 = `cert.ocr_image_ref`（资质图原始引用）。
-- 变更：新建 1 张表，业务表数 20 → 21（见《数据库设计文档》§1.3）。
-- 设计取舍：
--   · **不存被查看的原始内容**：本表只承载「谁在何时申请看哪条认证、谁复核、结论」，
--     原始信息（`ocr_image_ref`）仍唯一存放于 `cert` 表，打开时经 cert 域 service 现取 ——
--     把内容抄进申请表等于给敏感数据开了第二个出口（对齐审计白名单纪律）。
--   · **不建唯一键**：去重口径「同发起人对同一条认证已有 pending 申请则跳过」含业务判断
--     （仅 pending 去重），故与 `ops_follow_up` 同范式放到 service 显式判定。
--   · **无 reject_reason 列**：驳回理由属「必留操作」的留痕内容，落在 `audit_log.reason`
--     （同 V1 `cert.reject_reason` 与否的分工：本表只记结论与主体，理由进审计）。
-- EXPLAIN 结论：纯 DDL（CREATE TABLE），无 SELECT/DML，不适用。
-- =============================================================================

CREATE TABLE `admin_cert_access_request` (
  `id`           BIGINT       NOT NULL AUTO_INCREMENT                  COMMENT '复核申请 ID',
  `cert_id`      BIGINT       NOT NULL                                 COMMENT '目标认证记录 ID（cert.id）',
  `requester_id` BIGINT       NOT NULL                                 COMMENT '发起查看的管理员（admin_user.id）',
  `reason`       VARCHAR(255) NOT NULL                                 COMMENT '查看理由（必填，合规举证）',
  `status`       ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending'
                                                                        COMMENT '复核状态：待复核/已通过/已驳回',
  `reviewer_id`  BIGINT       NULL                                     COMMENT '复核人（admin_user.id；须与发起人不同，双人复核）',
  `reviewed_at`  DATETIME     NULL                                     COMMENT '复核时刻',
  `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP        COMMENT '申请时刻',
  PRIMARY KEY (`id`),
  KEY `idx_cert_access_status_created` (`status`, `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '认证原始信息敏感查看双人复核申请（PRD §9.10.1；[153] B2-5）';
