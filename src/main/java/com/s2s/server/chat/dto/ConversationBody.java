package com.s2s.server.chat.dto;

import java.util.List;

/**
 * 举报工单对应的会话正文（V30 / 计划 U7；仅供后台复核，不作为 App 接口出参）。
 *
 * <p><b>为什么不做 {@code visible_to} 过滤</b>：正文复核要看清双方往来的全貌，
 * 联系方式卡虽然只对被同意人可见，但它本身不含号码（R22），对审核员展示不构成
 * 信息外泄；真正的敏感出口仍是取号接口。读取动作由 admin 域逐次写审计留痕。</p>
 *
 * @param conversationId 会话 ID（举报对应的双方会话）
 * @param messages       最近一页消息（按 seq 正序；超出单页上限时只回落最新的一页）
 */
public record ConversationBody(
        Long conversationId,
        List<MessageItem> messages) {
}
