-- =============================================================================
-- V10__admin_user.sql — 运营治理后台账号体系（[153] B2-5）
-- =============================================================================
-- 出处口径：
--   · PRD §9.10.1「后台权限模型（4 角色，最小权限）」：内容审核员 / 运营专员 /
--     算法运营 / 超级管理员；§9.10.1「账号与角色管理」为超级管理员职责。
--   · 《决策登记表》2026-10-12（B2-5 开工批）：① 后台账号载体 = **新建独立
--     `admin_user` 表**（与 C 端 `user` 隔离，后台账号不混入 C 端用户表）；
--     ② 角色枚举扩充覆盖 PRD 四角色（新增 `operator` / `algo`）。
-- 变更一：新建 `admin_user`（后台账号，不计入原 16 张业务表面向 C 端的口径，
--   业务表数 16 → 17；见《数据库设计文档》§1.3）。
-- 变更二：`audit_log.operator_role` 扩枚举 —— PRD 四角色映射
--   超级管理员→super_admin／内容审核员→auditor／运营专员→operator／算法运营→algo；
--   历史值 `admin` 保留不删（无消费方无存量数据，避免 MODIFY 触及存量行）。
-- EXPLAIN 结论：纯 DDL（CREATE TABLE + ALTER TABLE MODIFY），无 SELECT/DML，不适用。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

CREATE TABLE `admin_user` (
  `id`            BIGINT      NOT NULL AUTO_INCREMENT               COMMENT '管理员 ID',
  `username`      VARCHAR(64) NOT NULL                              COMMENT '登录名（唯一）',
  `password_hash` VARCHAR(255) NOT NULL                             COMMENT '口令哈希（PBKDF2-HMAC-SHA256，格式 pbkdf2$迭代$盐b64$哈希b64；禁存明文）',
  `role`          ENUM('super_admin','auditor','operator','algo') NOT NULL COMMENT '后台角色（PRD §9.10.1 四角色，与 OperatorRole 同源）',
  `status`        ENUM('active','disabled') NOT NULL DEFAULT 'active' COMMENT '账号状态；disabled 禁止登录',
  `last_login_at` DATETIME    NULL                                  COMMENT '最近登录时刻',
  `created_at`    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP    COMMENT '创建时间',
  `updated_at`    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_admin_username` (`username`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '运营治理后台账号（[153] B2-5；与 C 端 user 隔离）';

ALTER TABLE `audit_log`
    MODIFY COLUMN `operator_role`
        ENUM('super_admin','admin','auditor','operator','algo','system','user') NOT NULL
        COMMENT '操作人角色（后台四角色 super_admin/auditor/operator/algo + 历史值 admin + system/user）';
