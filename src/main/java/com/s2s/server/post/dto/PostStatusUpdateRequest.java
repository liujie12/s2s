package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

/**
 * 帖子状态变更入参（[127]；对应 openapi {@code PATCH /posts/{post_id}/status} 请求体）。
 *
 * <p><b>{@code version} 必带且服务端不得兜底</b>（PRD §13.2、编码规范 §4.9）：缺失即
 * Bean Validation 拒绝 → {@code GlobalExceptionHandler} 映射 {@code 40001}，
 * 绝不允许「没传就跳过版本校验」——一兜底乐观锁就彻底失效且没人会发现。</p>
 *
 * @param action  变更动作（{@code offline} 下架 / {@code republish} 重新上架 /
 *                {@code renew} 延期）；合法值校验在 service 完成（同回 {@code 40001}）
 * @param version 客户端持有的乐观锁版本号（{@code GET /posts/{id}} 或
 *                {@code GET /posts/mine} 取回，原样回传）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostStatusUpdateRequest(
        @NotBlank(message = "action") String action,
        @NotNull(message = "version") Long version) {
}
