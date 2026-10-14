package com.s2s.server.ai.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * AI 智能发布解析入参（B2-4；对应 openapi {@code AiParseRequest}）。
 *
 * <p>四模式共用本载荷（PRD §5.9）：① 多媒体 7 秒（{@code mediaId} + {@code text}）、
 * ② 语音零键盘（{@code voiceMediaId}，服务端走已备案模型 ASR）、③ 对话式（{@code text}
 * 逐轮累积）、④ 抢发（{@code mediaId} + {@code text} 标题）。</p>
 *
 * <p><b>至少一项输入非空</b>（{@code mediaId}/{@code voiceMediaId}/{@code voiceText}/
 * {@code text} 任一），否则 {@code 40001}（由 {@code AiParseService} 校验）。</p>
 *
 * @param mediaId           图片媒体 ID（模式①/④；须为本人已上传媒体）
 * @param voiceMediaId      音频媒体 ID（模式②；服务端走 ASR 后再进 Scope 管线）
 * @param voiceText         客户端已转写的语音文本（可空；与 {@code voiceMediaId} 二选一，本字段优先）
 * @param text              自由文本输入（模式③逐轮 / 模式④标题 / 模式①补充一句话）
 * @param kind              类型（resource/demand，可空；用于需求态标题前缀与 scope）
 * @param leafCategoryId    当前已选叶子类目 ID（可空；用于模板 scope 的 P 集合）
 * @param completenessLevel 当前草稿完整度档（0/1/2，可空；仅用于回填配额快照的 limit，不参与猜测）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AiParseRequest(
        String mediaId,
        String voiceMediaId,
        String voiceText,
        String text,
        String kind,
        Integer leafCategoryId,
        Integer completenessLevel) {
}
