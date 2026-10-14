package com.s2s.server.ai.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;
import java.util.Map;

/**
 * AI 解析结果（B2-4；对应 openapi {@code AiParseResult}）。
 *
 * <p>承载「严格 Scope 四步管线」的产出一面（PRD §5.10）：猜测四件套 + 逐字段来源 +
 * 拒绝注入的字段 + 配额快照。<b>本结果不含任何未通过 Step 4 校验的值。</b></p>
 *
 * @param guess            四件套猜测（仅含通过逆向比对的值）
 * @param scopeVerified    已注入字段的来源（键为字段名，值取 user_input/neighbor_mode/platform）；
 *                         未列入的字段即未猜出（PRD §5.10 Step 2 的 U/N/P 三集合）
 * @param unresolvedFields Step 4 判定越界或无法溯源而<b>拒绝注入</b>的字段（服务端留空不猜）
 * @param quota            本次解析后的配额快照（只读展示；本端点不扣减）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AiParseResult(
        AiGuess guess,
        Map<String, String> scopeVerified,
        List<String> unresolvedFields,
        AiQuota quota) {
}
