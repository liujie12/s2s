package com.s2s.server.auth.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 修改我的设置请求（openapi {@code SettingsUpdateRequest}；{@code PATCH /settings}）。
 *
 * <p>局部更新：{@code null}/缺省字段不动；隐私项为只读，不入本请求。</p>
 *
 * @param notifyPatch   通知开关补丁（{@code null} 表示不动；子字段 {@code null} 表示该通道不动；JSON 键为 {@code notify}）
 * @param defaultRadius 默认检索半径档位（{@code null} 表示不动）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SettingsUpdateRequest(
        // 组件名不能叫 notify（与 Object.notify() 冲突），JSON 键仍为 notify
        @JsonProperty("notify") NotifyPatch notifyPatch,
        String defaultRadius) {

    /**
     * 通知开关补丁（openapi {@code SettingsUpdateRequest.notify}）。
     *
     * @param enabled     消息通知总开关；{@code null}=不动
     * @param system      系统通知分通道；{@code null}=不动
     * @param interaction 互动通知分通道；{@code null}=不动
     * @param cert        认证通知分通道；{@code null}=不动
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record NotifyPatch(Boolean enabled, Boolean system, Boolean interaction, Boolean cert) {
    }
}
