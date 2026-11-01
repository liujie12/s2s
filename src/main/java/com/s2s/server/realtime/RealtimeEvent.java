package com.s2s.server.realtime;

/**
 * 实时事件（Redis 总线载荷）。
 *
 * <p>发布方在<b>事务提交后</b>写总线，订阅方按 {@link #userId()} 找到本机连接投递；
 * {@code userId} 只在服务端实例之间流转，<b>不下发客户端</b>
 * （客户端只收到 {@link RealtimeClientPayload}）。</p>
 *
 * <p>载荷纪律（与推送一致，R14）：只带会话 ID 与序号，<b>不含消息正文、联系方式
 * 与对方昵称</b>。客户端收到后按 {@code seq} 增量拉取，正文只走 HTTP。</p>
 *
 * @param type           事件类型（当前只有 {@code message.new}）
 * @param userId         接收方 user_id（路由键，不出网关）
 * @param conversationId 会话 ID
 * @param seq            新消息序号（客户端增量拉取的游标下界）
 * @param senderId       发送方 user_id（供客户端判断是否为自己其它端发出）
 */
public record RealtimeEvent(String type, Long userId, Long conversationId, Integer seq,
        Long senderId) {
}
