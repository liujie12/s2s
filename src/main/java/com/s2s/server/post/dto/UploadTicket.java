package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * OSS 直传票据（[125]；对应 openapi {@code UploadTicket}）。
 *
 * <p>客户端拿到后直传 OSS，不经过应用服务器；{@code media_id} 与对象名均由服务端
 * 生成，客户端不可指定（安全方案 §5.1 约束⑤）。</p>
 *
 * @param mediaId   媒体 ID（服务端生成）
 * @param uploadUrl 带签名的短时效直传地址（客户端不持长期密钥）
 * @param expireAt  票据到期时间（24h 未 commit 的 pending 记录由定时任务清理）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record UploadTicket(
        String mediaId,
        String uploadUrl,
        Instant expireAt) {
}
