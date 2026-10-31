package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 置已读结果（V30 / 计划 U4；openapi {@code POST /conversations/{id}/read} 响应 {@code data}）。
 *
 * <p>返回推进后的水位便于客户端对齐本地红点：服务端只增不减（{@code GREATEST}），
 * 重复提交不会把已读退回未读。</p>
 *
 * @param lastReadSeq 推进后的已读水位（该会话全部消息均视为已读，R10）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ReadResult(
        Integer lastReadSeq) {
}
