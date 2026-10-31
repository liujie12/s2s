package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 消息功能总开关出参（V30 / U8；R30）。
 *
 * @param enabled 总开关：{@code false} 时创建会话、发放申请卡与发送消息一律拒绝，
 *                存量会话只读；缺配置行按开启
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessageSwitchResponse(
        boolean enabled) {
}
