package com.s2s.server.ai.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * AI 配额快照（B2-4；对应 openapi {@code AiQuota}，PRD §5.8 二维配额表）。
 *
 * <p>只读展示。<b>扣减唯一发生在 {@code POST /posts}（带 {@code ai_assisted=true}）</b>，
 * 解析端点不扣减（PRD §5.9「仅确认发布才计 1 次」）。</p>
 *
 * @param used    今日已用 AI 解析次数（仅「确认发布」计入）
 * @param limit   今日上限（实名状态 × 完整度档；高敏类目额外 +10）
 * @param resetAt 配额重置时间（次日 00:00，Asia/Shanghai）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AiQuota(
        Integer used,
        Integer limit,
        Instant resetAt) {
}
