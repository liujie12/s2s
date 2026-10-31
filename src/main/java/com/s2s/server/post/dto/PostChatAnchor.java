package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 会话锚点：chat 域开会话前需要的帖子最小信息（V30 / 计划 U2）。
 *
 * <p><b>为什么单独出一个 DTO 而不是把 {@code PostEntity} 交给 chat 域</b>：
 * 域间只调对方 service（编码规范 §4.2），且聊天只需要「谁发布的、帖子是否对他人可见、
 * 要不要申请」三件事——把整个实体暴露出去等于把帖子的写模型泄漏给读场景。</p>
 *
 * @param postId        帖子 ID
 * @param ownerId       发布者 user_id（会话的另一方）
 * @param status        库内状态原值（由 chat 域用 {@code PostStatus} 判定可见性）
 * @param applyRequired 查看联系方式是否需申请
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostChatAnchor(
        Long postId,
        Long ownerId,
        String status,
        boolean applyRequired) {
}
