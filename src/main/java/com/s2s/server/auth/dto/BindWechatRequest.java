package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 绑定微信请求（B2-6a；对应 openapi {@code POST /auth/wechat/bind} 请求体）。
 *
 * <p>语义：登录态用户（典型为手机号老账号）把微信身份挂到当前账号。
 * 微信身份已属于其他账号时拒绝（40302），不自动迁移数据。</p>
 *
 * @param code 微信授权 code（一次性，最长 64 字符，由客户端微信 SDK 获得）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record BindWechatRequest(
        @NotBlank @Size(max = 64) String code) {
}
