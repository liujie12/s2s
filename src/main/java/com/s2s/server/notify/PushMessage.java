package com.s2s.server.notify;

/**
 * 推送消息载荷（[B2-2]；PRD §8.3.3 纯通知形态）。
 *
 * <p>字段刻意与站内通知同源（{@code type}/{@code title}/{@code summary}/{@code target_id}）：
 * 用户在通知栏点开后要跳到与站内通知**同一个落点**，两条链路的载荷不同源迟早会跳岔。</p>
 *
 * <p><b>纯通知形态</b>：PRD §12.3 / §8.3.3 明写「推送为纯通知形态，无消息列表、无聊天详情
 * （附录 B）」——故本载荷不含会话/消息 ID 之类可承载双向通信的字段。</p>
 *
 * @param type     通知类型（决定客户端点击后的落点，与站内通知同口径）
 * @param title    标题（≤64，调用方保证，与 {@code notification.title} 同长）
 * @param summary  摘要（可空，≤256，与 {@code notification.summary} 同长）
 * @param targetId 关联对象 ID（可空；{@code type=cert} 时恒空）
 */
public record PushMessage(NotifyType type, String title, String summary, Long targetId) {
}
