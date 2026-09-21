package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 发送短信验证码响应（[123] U3；对应 openapi {@code POST /auth/sms/send} 响应 {@code data}）。
 *
 * <p>字段与契约逐字对齐：{@code expire_in}（验证码有效期，秒）。</p>
 *
 * @param expireIn 验证码有效期（秒），契约示例 {@code 300}
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SendCodeResult(int expireIn) {
}
