package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 帖子状态变更结果（[127]；对应 openapi {@code PATCH /posts/{post_id}/status} 响应
 * {@code data}）。
 *
 * <p>{@code version} 为变更<b>后</b>的新版本号，客户端据它继续后续乐观锁操作。</p>
 *
 * @param id       帖子 ID
 * @param status   变更后的状态（API 值，见 {@code PostStatus#toApi}）
 * @param expireAt 变更后的到期时间
 * @param version  变更后的新版本号
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostStatusResult(
        Long id,
        String status,
        Instant expireAt,
        Long version) {
}
