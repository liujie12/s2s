package com.s2s.server.realtime;

/**
 * 下发给客户端的实时事件载荷。
 *
 * <p>与 {@link RealtimeEvent} 分开定义是刻意的：路由字段（接收方 user_id）与发送方
 * user_id 都不出网关，客户端只知道「哪个会话来了第几条」。这样即使连接被中间人观察，
 * 也拿不到任何身份或内容信息。</p>
 *
 * @param type           事件类型（{@code message.new} / {@code conversation.read}）
 * @param conversationId 会话 ID
 * @param seq            新消息序号（新消息事件有效）
 * @param readSeq        已读水位（已读事件有效）
 */
public record RealtimeClientPayload(String type, Long conversationId, Integer seq,
        Integer readSeq) {
}
