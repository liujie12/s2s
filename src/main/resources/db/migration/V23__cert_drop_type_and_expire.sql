-- =============================================================================
-- V23 — 资质认证简化为「名称 + 图片」，取消类型与有效期（2026-10-28）
--
-- 背景（产品已拍板）：资质认证从「三选证件类型 + 有效期」简化为「证书名 + 证照图」。
--   1) 资质不再有过期概念：cert 去掉 expired 状态与每日过期任务；
--   2) 证件类型不再由用户选择：资质统一落 cert_type=personal_qualification；
--   3) 帖级凭证声明只需证名快照，其余快照列随之删除。
--
-- 保留说明：cert.cert_type 列必须保留（个人实名 personal_realname 与本表共用），
--   仅从接口面移除，不在本迁移中删除。
--
-- 依据：docs/api/openapi.yaml（CertOcrResult / Qualification* / PostCredential）
--       docs/PRD.md §12 认证接口、§4.7 认证口径
-- 纪律：已应用的迁移不可改（V1–V22 保持原样），本文件为新增版本。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) 先搬运存量数据：历史 expired 行按 approved 处理
--    必须在收紧 ENUM 之前执行，否则 MySQL 严格模式下 MODIFY 会报数据截断。
-- -----------------------------------------------------------------------------
UPDATE `cert` SET `status` = 'approved' WHERE `status` = 'expired';

-- -----------------------------------------------------------------------------
-- 2) cert.status 收紧为三态：pending / approved / rejected
--    原注释语义（认证状态）保留。
-- -----------------------------------------------------------------------------
ALTER TABLE `cert`
  MODIFY COLUMN `status` ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending' COMMENT '认证状态';

-- -----------------------------------------------------------------------------
-- 3) 删除有效期相关列与扫描索引
--    idx_status_expire 由 V22 建立（status, expire_at），随 expire_at 一并删除。
--    说明：本 SQL 为标准写法，依赖 V22 已执行；若目标库缺该索引，请先核对
--    V22 执行记录后再手工去掉 DROP KEY 子句，不要改动本文件。
-- -----------------------------------------------------------------------------
ALTER TABLE `cert`
  DROP KEY `idx_status_expire`,
  DROP COLUMN `expire_type`,
  DROP COLUMN `expire_at`;

-- -----------------------------------------------------------------------------
-- 4) 帖级凭证声明只保留证名快照：删除类型/有效期/关联瞬间状态快照
--    cert_name_snapshot 与 declared_at 保留（详情只显示证书名）。
-- -----------------------------------------------------------------------------
ALTER TABLE `post_cert_declaration`
  DROP COLUMN `cert_type`,
  DROP COLUMN `expire_type_snapshot`,
  DROP COLUMN `expire_at_snapshot`,
  DROP COLUMN `cert_status_snapshot`;
