package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 会话列表行（V30 / 计划 U4；openapi {@code GET /conversations} 的 {@code items[]}）。
 *
 * <p><b>红点用布尔值</b>：R9 规定普通会话行只显示红点、不显示条数，故这里只出
 * {@code unread}；条数口径只在未读汇总接口（U5）出现，避免两处各算一套。</p>
 *
 * <p><b>帖子下架只置灰不出证据</b>：{@code post_gone} 为真时客户端把缩略图置灰并标注
 * 「已下架」，会话仍可打开（R4）；下架原因不在此暴露。</p>
 *
 * @param conversationId    会话 ID
 * @param postId            会话所锚定的帖子 ID
 * @param postTitle         帖子标题（列表行展示；帖子删除后仍保留会话时可能为 null）
 * @param postGone          帖子是否对他人不可见（下架/过期；R4）
 * @param peerId            对方 user_id
 * @param peerNickname      对方昵称
 * @param peerAvatarUrl     对方头像 URL（可空）
 * @param lastMessageType   最后一条消息类型（text/apply/contact），空会话为 null
 * @param lastMessagePreview 最后一条消息摘要（发送时截断写入，仅供列表展示）
 * @param lastMessageAt     最后一条消息时刻（UTC）
 * @param unread            是否有未读（红点；不含本人发出的消息）
 * @param applyStatus       申请卡状态（none/pending/approved/rejected；U6 渲染入口态）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationItem(
        Long conversationId,
        Long postId,
        String postTitle,
        boolean postGone,
        Long peerId,
        String peerNickname,
        String peerAvatarUrl,
        String lastMessageType,
        String lastMessagePreview,
        Instant lastMessageAt,
        boolean unread,
        String applyStatus) {
}
