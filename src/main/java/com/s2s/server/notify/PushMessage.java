package com.s2s.server.notify;

/**
 * 推送消息载荷（[B2-2]；PRD §8.3.3 纯通知形态；V30 / U9 新增会话落点）。
 *
 * <p>字段刻意与站内通知同源（{@code type}/{@code title}/{@code summary}/{@code target_id}）：
 * 用户在通知栏点开后要跳到与站内通知<b>同一个落点</b>，两条链路的载荷不同源迟早会跳岔。</p>
 *
 * <p><b>纯通知形态</b>：PRD §12.3 / §8.3.3 明写「推送为纯通知形态，无消息列表、无聊天详情
 * （附录 B）」——故本载荷不含会话/消息 ID 之类可承载双向通信的字段。</p>
 *
 * <p><b>{@code landingType} 是 V30 的唯一扩展</b>：站内消息推送不写 {@code notification} 表
 * （KTD6），无法靠 {@code type} 反推落到哪个页面，故显式携带落点类型。新增值时只允许
 * 与客户端约定好的固定枚举；{@code null} 表示沿用 {@code type} 的既有落点（三类通知）。</p>
 *
 * @param type        通知类型（决定客户端点击后的落点，与站内通知同口径）
 * @param title       标题（≤64，调用方保证，与 {@code notification.title} 同长）
 * @param summary     摘要（可空，≤256，与 {@code notification.summary} 同长）
 * @param targetId    关联对象 ID（可空；{@code type=cert} 时恒空；会话落点时为会话 ID）
 * @param landingType 落点类型（可空；{@link #LANDING_CONVERSATION} 表示打开对应会话）
 */
public record PushMessage(NotifyType type, String title, String summary, Long targetId,
        String landingType) {

    /** 落点：打开会话详情（V30 / R14 / R16a）。载荷只带会话 ID，不含正文与联系方式。 */
    public static final String LANDING_CONVERSATION = "conversation";

    /**
     * 构造「落点由 {@code type} 推导」的推送载荷（三类通知的既有形态）。
     *
     * @param type     通知类型
     * @param title    标题
     * @param summary  摘要
     * @param targetId 关联对象 ID
     */
    public PushMessage(NotifyType type, String title, String summary, Long targetId) {
        this(type, title, summary, targetId, null);
    }
}
