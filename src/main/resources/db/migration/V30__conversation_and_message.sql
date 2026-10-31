-- =============================================================================
-- V30 — 站内 1:1 会话与消息（2026-10-31）
--
-- 背景：详情页原先只有一条「看号」短路，联系发生后平台看不到任何往来。
--   本版新增会话 / 会话成员 / 消息三张表，把沟通留在站内；已读只用
--   conversation_member.last_read_seq 一个水位（未读由「消息 seq > 水位」推导，
--   不存计数器），会话内 seq 单调递增、兼作增量游标。
--
-- 口径（依据 docs/plans/2026-10-31-2048-feat-detail-chat-and-message-center-plan.md）：
--   · KTD1 三实体 + 水位式未读；KTD2 申请卡状态挂会话行、卡片本身是消息行；
--   · KTD3 seq 单调递增（会话行加锁自增 last_seq）；KTD8 90 天隐藏是查询条件；
--   · KTD11 一个会话只写一条 contact_event（渠道扩「会话 / 申请」两值）。
--
-- 纪律：已应用迁移不可改，本文件为新增版本（继 V29 之后）。
-- EXPLAIN 结论：本迁移为纯 DDL + 种子 INSERT（无 SELECT/UPDATE/DELETE 查询语句），
--   EXPLAIN 不适用（编码规范 §2.2 的「无结论视为未完成」按此注明豁免）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：conversation — 会话（一条帖子 + 一个发起人 唯一）
-- -----------------------------------------------------------------------------
CREATE TABLE `conversation` (
  `id`                   BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '会话 ID',
  `post_id`              BIGINT       NOT NULL                        COMMENT '会话所锚定的帖子 ID（下架不失效）',
  `initiator_id`         BIGINT       NOT NULL                        COMMENT '发起人 user_id（会话的一方）',
  `owner_id`             BIGINT       NOT NULL                        COMMENT '帖子发布者 user_id（会话的另一方）',
  `last_seq`             INT          NOT NULL DEFAULT 0              COMMENT '会话内消息序号水位：发送时加锁自增，消息行取该值（KTD3）',
  `last_message_at`      DATETIME     NULL                            COMMENT '最后一条可见消息时刻（列表倒序与 90 天隐藏窗口的唯一依据；空=尚无消息）',
  `last_message_type`    VARCHAR(16)  NULL                            COMMENT '最后一条消息类型（text/apply/contact），列表摘要按类型选文案',
  `last_message_preview` VARCHAR(128) NULL                            COMMENT '最后一条消息摘要（发送时写入，仅供列表展示，不作为正文真源）',
  `apply_status`         ENUM('none','pending','approved','rejected') NOT NULL DEFAULT 'none'
                                                                       COMMENT '联系方式申请卡状态：同会话始终只有一张卡（KTD2）',
  `apply_at`             DATETIME     NULL                            COMMENT '申请卡最近一次提交时刻（72h 重申窗口起算点）',
  `apply_decided_at`     DATETIME     NULL                            COMMENT '申请卡最近一次审批时刻（7 天冷却起算点）',
  `created_at`           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_post_initiator` (`post_id`, `initiator_id`)
    COMMENT '同一帖子与同一发起人全生命周期只有一条会话（R5：隐藏后复用原会话，永不出现第二条）',
  KEY `idx_last_message_at` (`last_message_at`) COMMENT '列表倒序与 90 天隐藏窗口的查询下界'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '站内 1:1 会话—帖子寿命与会话解耦，90 天无往来仅隐藏不删除';

-- -----------------------------------------------------------------------------
-- 表：conversation_member — 会话成员（双方各一行）
-- -----------------------------------------------------------------------------
CREATE TABLE `conversation_member` (
  `conversation_id` BIGINT   NOT NULL                  COMMENT '会话 ID',
  `user_id`         BIGINT   NOT NULL                  COMMENT '成员 user_id',
  `last_read_seq`   INT      NOT NULL DEFAULT 0        COMMENT '已读水位：未读 = 消息 seq > 本值（KTD1 唯一真源，不存计数）',
  `pushed_unread`   TINYINT  NOT NULL DEFAULT 0        COMMENT '未读期间已推送标记：1=已推过首条（KTD7，读会话时复位）',
  `created_at`      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`conversation_id`, `user_id`),
  KEY `idx_user` (`user_id`) COMMENT '按用户列会话（消息 Tab 列表与未读汇总）'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '会话成员—已读水位与已推送标记的唯一载体';

-- -----------------------------------------------------------------------------
-- 表：message — 会话消息（按 seq 排序）
-- -----------------------------------------------------------------------------
CREATE TABLE `message` (
  `id`              BIGINT       NOT NULL AUTO_INCREMENT         COMMENT '消息 ID',
  `conversation_id` BIGINT       NOT NULL                        COMMENT '会话 ID',
  `seq`             INT          NOT NULL                        COMMENT '会话内序号（同会话唯一，兼作增量游标与已读水位，KTD3）',
  `sender_id`       BIGINT       NOT NULL                        COMMENT '发送者 user_id（申请卡与联系方式卡为对应操作方）',
  `type`            ENUM('text','apply','contact') NOT NULL DEFAULT 'text' COMMENT '消息类型：text 文本 / apply 申请卡 / contact 联系方式卡',
  `content`         VARCHAR(500) NULL                            COMMENT '文本正文（服务端按 ChatLimits 上限校验；卡片类为 NULL；注销后置 NULL 表示已匿名化）',
  `visible_to`      BIGINT       NULL                            COMMENT '可见范围：非空即只对该 user_id 可见（仅联系方式卡使用）',
  `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '发送时刻',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_conversation_seq` (`conversation_id`, `seq`)
    COMMENT '会话内序号唯一：并发发送下既不重号也不漏号（KTD3）',
  KEY `idx_conversation_visible_seq` (`conversation_id`, `visible_to`, `seq`)
    COMMENT '消息分页 / 增量拉取 / 未读推导（按会话 + 可见范围扫 seq 区间）'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '会话消息—文本与两类卡片同表，卡片可见性靠 visible_to';

-- -----------------------------------------------------------------------------
-- 既有表扩展
-- -----------------------------------------------------------------------------

-- 帖子：查看联系方式需申请（R19；默认不勾选，维持既有「一键取号」效率）
ALTER TABLE `post`
  ADD COLUMN `contact_apply_required` TINYINT NOT NULL DEFAULT 0
    COMMENT '查看联系方式需申请：0=否（默认一键取号）/1=是（先申请后可见）' AFTER `contact_mask`;

-- 联系事件：渠道扩两值与会话标识（KTD11：一个会话只写一条事件；申请同意时升级渠道）
ALTER TABLE `contact_event`
  MODIFY COLUMN `channel_type` ENUM('phone','wechat','conversation','apply') NOT NULL
    COMMENT '联系方式/沟通渠道：phone 电话 / wechat 微信 / conversation 会话 / apply 申请',
  ADD COLUMN `conversation_id` BIGINT NULL COMMENT '会话 ID（会话与申请渠道写入；其余渠道为 NULL）' AFTER `to_user_id`,
  ADD KEY `idx_conversation` (`conversation_id`) COMMENT '按会话去重与渠道升级定位';

-- 举报：新增「误拦」原因值（R28 误拦反馈复用同一处置队列；不改既有值顺序）
ALTER TABLE `report`
  MODIFY COLUMN `reason` ENUM('false_info','fraud','wrong_category','harassment','other','misblock') NOT NULL
    COMMENT '举报原因：不实信息/诈骗/违规类目/骚扰/其他/误拦';

-- 用户设置：新增独立的「消息通知」开关（R15；关闭只停推送，消息照常落库）
ALTER TABLE `user_setting`
  ADD COLUMN `notify_message` TINYINT NOT NULL DEFAULT 1
    COMMENT '新消息通知开关：0=关（不推送但消息照常落库）/1=开' AFTER `notify_cert`;

-- 系统配置：消息功能总开关种子值（R30；缺行口径按开启，种子显式写入便于运营定位）
INSERT INTO `system_config` (`config_key`, `config_value`, `description`, `version`)
VALUES ('message_enabled', 'on', '消息功能总开关 on/off；off 时创建会话、发放申请卡与发送消息一律拒绝，存量会话只读', 0);
