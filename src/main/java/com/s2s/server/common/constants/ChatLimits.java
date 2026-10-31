package com.s2s.server.common.constants;

/**
 * chat 域阈值常量（KTD12；主源 = 本类，前端 {@code NfrChat} 为其 Dart 镜像）。
 *
 * <p>职责：承载会话与消息链的<b>全部</b>业务阈值——未回复上限、隐藏窗口、
 * 申请冷却、重申窗口、正文长度与分页上限。业务代码只引用常量名，禁写字面量
 * （编码规范红线「不复制字面量」）。</p>
 *
 * <p><b>与 {@link RateLimitThresholds} 的分工</b>：每日新会话额度是「限频轨道」
 * （42902 + Retry-After），按规范必须落在 {@code RateLimitThresholds}；本类只承载
 * 非限频轨的业务阈值。两处都不得在业务代码里出现裸数字。</p>
 *
 * <p>出处：实施计划 {@code docs/plans/2026-10-31-2048-feat-detail-chat-and-message-center-plan.md}
 * KTD12，以及 Product Contract R5 / R21 / R26 / R28。</p>
 */
public final class ChatLimits {

    /**
     * 工具类：禁止实例化。
     */
    private ChatLimits() {
        throw new AssertionError("ChatLimits 是常量类，不可实例化");
    }

    // --- 治理额度 -----------------------------------------------------------------

    /** 未获回复时我方连续文本消息上限（R26 / K3）：达到即拒发，对方每回复一次重新计数。 */
    public static final int UNREPLIED_TEXT_LIMIT = 3;

    // --- 生命周期窗口 -------------------------------------------------------------

    /** 会话隐藏窗口天数（R5 / K4 / KTD8）：双方连续无往来超过该天数时从列表隐藏（数据保留），
     * 新的往来写入后自然重新可见——是查询下界，不是定时任务。 */
    public static final int CONVERSATION_HIDE_AFTER_DAYS = 90;

    /** 申请被拒后的再次申请冷却天数（R21 / R21a）：冷却内入口置灰，期满复用同一张卡。 */
    public static final int APPLY_REJECT_COOLDOWN_DAYS = 7;

    /** 待审批超过该小时数后允许再提交一次（R21）：防申请卡长期悬挂无人处理。 */
    public static final int APPLY_PENDING_REAPPLY_HOURS = 72;

    // --- 输入与分页 ---------------------------------------------------------------

    /** 消息正文长度上限（字符）。与 {@code message.content} 列宽一致，服务端先校验再落库。 */
    public static final int MESSAGE_CONTENT_MAX_LENGTH = 500;

    /** 会话列表默认分页大小（未传 {@code page_size} 时使用）。 */
    public static final int CONVERSATION_PAGE_DEFAULT_SIZE = 20;

    /** 会话列表单页上限：超出即按本值钳制，避免一次拉全量。 */
    public static final int CONVERSATION_PAGE_MAX_SIZE = 50;

    /** 消息分页默认大小（翻历史时未传 {@code page_size} 时使用）。 */
    public static final int MESSAGE_PAGE_DEFAULT_SIZE = 30;

    /** 消息分页单页上限：超出即按本值钳制。 */
    public static final int MESSAGE_PAGE_MAX_SIZE = 100;

    // --- 展示口径 -----------------------------------------------------------------

    /** 未读角标展示上限（R9 / R11）：总数超过该值时显示「99+」（前端 {@code NfrChat} 同值）。 */
    public static final int UNREAD_BADGE_MAX = 99;

    /** 列表摘要保留字符数：写入 {@code conversation.last_message_preview} 时的截断长度，
     * 只影响列表展示，不改变正文真源。 */
    public static final int LIST_PREVIEW_MAX_LENGTH = 40;
}
