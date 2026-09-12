-- =============================================================================
-- s2s 二手交易 App — 埋点库 Batch1 首版 schema
-- =============================================================================
-- 适用 MySQL 8.4 LTS，Flyway 命名 V1__init_track_schema.sql
-- 独立 database（架构 R14：埋点与业务数据分库、同一 MySQL 实例），
-- 与业务库 V1__init_schema.sql 互不干扰。
-- 本脚本内两张表均为运维基础设施表，**不计入「15 张业务表」口径**。
-- 依据：docs/architecture/可观测性架构方案.md §4.4、
--      docs/plans/2026-09-04-1630-refactor-batch1-data-model-corrections-plan.md U1
--
-- 执行方式（Batch1 现状）：由 docker-entrypoint-initdb.d 在容器首次启动时执行。
--   必须自行 CREATE DATABASE + USE：entrypoint 只会创建 MYSQL_DATABASE（业务库）
--   并把会话切进业务库，埋点库不在其管辖范围。若省略下面两行，两张埋点表会被
--   建到业务库里、而 s2s_track 库根本不存在 —— 应用连埋点 datasource 时直接失败。
--   库名与 .env 的 MYSQL_TRACK_DATABASE 必须保持一致（当前口径：s2s_track）。
--   编码期引入 Flyway 后改由独立 Flyway datasource 执行，届时本段作废。
-- =============================================================================

-- [KTD-5 迁移副本注] 本文件复制自 docs/database/ddl/V1__init_track_schema.sql
-- [KTD-5 迁移副本注] （源 SHA-256: B9542C68135A75FA704078AB6E18143E6A1A4733DFD2732FE30EA9E5131C48FD），
-- [KTD-5 迁移副本注] 仅剔除 CREATE DATABASE/USE/GRANT 三句（KTD-5 定案），其余内容与源逐行一致。
-- [KTD-5 迁移副本注] CREATE DATABASE IF NOT EXISTS `s2s_track` 与 USE 两句已剔除：建库是 initdb
-- [KTD-5 迁移副本注] 专用动作（deploy/initdb.d/01-init-databases.sh，KTD-4），应用账号无 CREATE DATABASE
-- [KTD-5 迁移副本注] 权限；Flyway 连接 URL 已指定库名（TRACK_DATASOURCE_URL），无需 USE。

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- 表：track_event_202609 — 埋点事件月表（首月表，R8/R18 落点）
-- 结构真源：可观测性架构方案 §4.4（宽表：公共字段拆列 + JSON 属性列）
-- 按月分表命名 track_event_YYYYMM；每月 25 日由「埋点月表预建」定时任务建下月表（架构 §8）
-- 跨月归属按 ts 而非到达时刻：9/30 采集、10/1 上报的事件仍写入 202609 表
-- 维度快照列（PRD:2253）：发布时刻的事实快照，使分析无需跨库 join、且不受后续改帖影响
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `track_event_202609`;
CREATE TABLE `track_event_202609` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '事件 ID',
  `event_name`          VARCHAR(64)  NOT NULL                        COMMENT '事件名（layer_switch/post_published/contact_event 等）',
  `interaction_id`      CHAR(36)     NOT NULL                        COMMENT '交互标识，客户端埋点与服务端访问日志的唯一 join 键（PRD §12.1）',
  `user_id`             BIGINT       NULL                            COMMENT '触发用户；未登录事件补报前为 NULL',
  `device_id`           CHAR(36)     NULL                            COMMENT '设备指纹（X-Device-Id），不可信，仅做限频与去重辅助',
  `ts`                  DATETIME(3)  NOT NULL                        COMMENT '采集时刻（非上报时刻），月表归属以此列为准',
  `props`               JSON         NULL                            COMMENT '事件专属属性（duration_ms/cache_hit/rank/channel_type 等）',
  `leaf_category_id`    INT          NULL                            COMMENT '维度快照：发布时叶子类目 ID',
  `completeness_level`  TINYINT      NULL                            COMMENT '维度快照：完整度档位 0=红/1=黄/2=绿',
  `is_ai_assisted`      TINYINT(1)   NULL                            COMMENT '维度快照：是否 AI 辅助发布 0/1',
  `grid_id`             VARCHAR(24)  NULL                            COMMENT '维度快照：发布点网格 ID；只能是发布点，严禁写入用户位置。宽度与业务库 post.grid_id 一致（同一列语义须同宽，否则跨库比对易踩截断）',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '入库时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_event_dedup` (`interaction_id`, `event_name`, `user_id`, `ts`)
    COMMENT '事件维度去重（详细设计 §17.4.1 的服务端前提）。客户端埋点批次每次组批换新 Idempotency-Key，故幂等键挡不住「响应丢在回程→整批重传」的重复，防线必须建在这里。落库须用 INSERT ... ON DUPLICATE KEY UPDATE id=id，严禁 INSERT IGNORE（后者会把数据截断、非空列插 NULL 一并降级为 warning，等于在写入路径关掉全部数据质量报错）。列序把 interaction_id 置最左：它基数最高（每次交互一个 UUID）故判重查询最快，且其最左前缀完全覆盖原 idx_interaction，该索引已因此删除——净增索引 0 个，写放大不增加',
  KEY `idx_event_ts` (`event_name`, `ts`)                            COMMENT '按事件名 + 时间窗算指标',
  KEY `idx_user_ts` (`user_id`, `ts`)                                COMMENT '按用户回溯行为序列'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '埋点事件月表（2026-09）—保留 90 天，异步旁路写入，允许丢；不可用于合规举证。去重靠 uk_event_dedup，不靠幂等键';

-- -----------------------------------------------------------------------------
-- 表：track_event_fallback — 埋点跨月写入兜底表（KTD4 落点，R18 双保险之二）
-- 与月表同结构、无分区、无业务索引；仅当写月表返回 1146（表不存在）时降级写入
-- 后台 @Scheduled 任务每分钟按 ts 搬运到正确月表并删除本表对应行
-- 缺此表则 KTD4 的兜底路径首次触发即失败，跨月零点的数据静默丢失
-- 刻意【不建】uk_event_dedup：本表是缓冲不是终点，去重只需在数据抵达终点时发生一次。
-- 搬运任务用 INSERT ... ON DUPLICATE KEY UPDATE id=id 写月表，月表的唯一索引会把
-- 兜底期间积累的重复一并消化掉。在此建唯一索引反而会拖慢降级路径的写入 ——
-- 而降级路径恰是最需要写得快、最不能再失败一次的时刻。
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `track_event_fallback`;
CREATE TABLE `track_event_fallback` (
  `id`                  BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '兜底行 ID',
  `event_name`          VARCHAR(64)  NOT NULL                        COMMENT '事件名',
  `interaction_id`      CHAR(36)     NOT NULL                        COMMENT '交互标识',
  `user_id`             BIGINT       NULL                            COMMENT '触发用户',
  `device_id`           CHAR(36)     NULL                            COMMENT '设备指纹',
  `ts`                  DATETIME(3)  NOT NULL                        COMMENT '采集时刻，搬运任务据此判定目标月表',
  `props`               JSON         NULL                            COMMENT '事件专属属性',
  `leaf_category_id`    INT          NULL                            COMMENT '维度快照：叶子类目 ID',
  `completeness_level`  TINYINT      NULL                            COMMENT '维度快照：完整度档位',
  `is_ai_assisted`      TINYINT(1)   NULL                            COMMENT '维度快照：是否 AI 辅助发布',
  `grid_id`             VARCHAR(24)  NULL                            COMMENT '维度快照：发布点网格 ID',
  `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '入库时间',
  PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci COMMENT = '埋点跨月兜底表—无分区无索引，仅缓冲；搬运完成即删行，常态应为空表';

-- [KTD-5 迁移副本注] 原「授权」段（注释块 + GRANT SELECT,INSERT,UPDATE,DELETE + FLUSH PRIVILEGES）
-- [KTD-5 迁移副本注] 已剔除：授权是 initdb 专用动作，由 deploy/initdb.d/01-init-databases.sh 以 root 统一执行。
-- [KTD-5 迁移副本注] 新口径（KTD-4）为两库 GRANT ALL PRIVILEGES —— Flyway 迁移与埋点月表预建
-- [KTD-5 迁移副本注] （详设 §6 #2，CREATE TABLE ... LIKE）均以应用账号执行，必须持 DDL 权限；
-- [KTD-5 迁移副本注] 源文件「只授 DML、月表预建由运维 root 执行」为 initdb 时代旧口径，随本剔除作废。
