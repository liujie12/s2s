package com.s2s.server.auth.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 我的设置响应（openapi {@code SettingsResponse}；{@code GET/PATCH /settings} 的 {@code data}）。
 *
 * @param notifySettings 通知开关（缺行时为全默认＝四项全开；JSON 键为 {@code notify}）
 * @param defaultRadius 默认检索半径档位（{@code 1}/{@code 3}/{@code 5}/{@code 10}/{@code city}）
 * @param privacy       隐私项（只读展示）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SettingsResponse(
        // 组件名不能叫 notify（与 Object.notify() 冲突），JSON 键仍为 notify
        @JsonProperty("notify") NotifySettings notifySettings,
        String defaultRadius,
        PrivacySettings privacy) {

    /**
     * 通知开关（openapi {@code SettingsResponse.notify}；PRD §9.3）。
     *
     * @param enabled     消息通知总开关
     * @param system      系统通知分通道
     * @param interaction 互动通知分通道
     * @param cert        认证通知分通道
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record NotifySettings(boolean enabled, boolean system, boolean interaction, boolean cert) {
    }

    /**
     * 隐私项（openapi {@code SettingsResponse.privacy}；只读展示，PATCH 提交即忽略）。
     *
     * @param contactDisplay 联系方式展示策略，恒 {@code transit_only}
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record PrivacySettings(String contactDisplay) {
    }
}
