-- =============================================================================
-- V2__restart_window.sql — 服务端启动时间窗表
-- 详设 §21 #1：服务端启动自写（本迁移只建表；写入动作由服务端启动流程落地，无客户端接口）
-- =============================================================================
-- 出处口径：
--   · 详设 §21 #1：restart_window 未在 V1 建表，补两列 DDL + 服务端启动自写；
--   · 可观测性架构方案 §4.2.2：表名 restart_window、两列 start_at/end_at，
--     「应用启动时自身写入一行，end_at = 启动完成时刻 + 5 分钟」；
--     并明确「放在服务端业务 database 而不是埋点 database」——故本迁移位于业务库目录；
--   · 详设 §17.3：P95 分母排除重启预热期的唯一落点。
-- 查询形态（可观测性 §4.2.2 唯一消费方）：
--   NOT EXISTS (SELECT 1 FROM restart_window w WHERE e.ts BETWEEN w.start_at AND w.end_at)
--   行数 == 启动次数（极少），全表扫描即可，故不建额外索引。
-- EXPLAIN 结论：本迁移为纯 DDL（CREATE TABLE，无 SELECT/DML 查询语句），
--   EXPLAIN 不适用（编码规范 §2.2 要求的「无结论视为未完成」按此注明豁免）。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行，
--   写 DROP 会让误重跑的破坏面扩大（与 V1 存档脚本的 initdb 时代写法刻意区分）。
-- =============================================================================

CREATE TABLE `restart_window` (
  `id`         BIGINT   NOT NULL AUTO_INCREMENT COMMENT '行 ID（遵循全库 15 表统一主键惯例，供运维清理与行定位）',
  `start_at`   DATETIME NOT NULL                COMMENT '启动时刻（应用开始启动）',
  `end_at`     DATETIME NOT NULL                COMMENT '预热期结束时刻 = 启动完成时刻 + 5 分钟（可观测性 §4.2.2）',
  PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '服务端启动时间窗—详设 §21 #1：服务端启动自写，算 P95 时剔除落在窗口内的事件';
