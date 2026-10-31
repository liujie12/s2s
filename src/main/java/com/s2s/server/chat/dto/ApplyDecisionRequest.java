package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 申请审批入参（V30 / 计划 U6；openapi {@code POST /conversations/{id}/apply/decision}）。
 *
 * <p>只收「同意 / 拒绝」一个布尔值：申请人、会话与卡片都由路径与登录态确定，
 * 客户端无法替他人审批或伪造卡片。</p>
 *
 * @param approved true=同意（写入仅申请人可见的联系方式卡）；false=拒绝（满冷却期可再次申请）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ApplyDecisionRequest(
        @NotNull(message = "approved") Boolean approved) {
}
