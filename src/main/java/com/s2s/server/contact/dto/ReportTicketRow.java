package com.s2s.server.contact.dto;

import java.time.LocalDateTime;

/**
 * 举报工单行（[153] B2-5 ④；contact 域内部出参，供 admin 域映射）。
 *
 * <p>{@code riskScore} 取自被举报帖子的 {@code post.risk_score}（累计值）——
 * 工单按它排序（PRD §9.10.1 ④「按风险分排序」）。</p>
 *
 * @param reportId       举报 ID
 * @param postId         被举报帖子 ID
 * @param postTitle      被举报帖子标题
 * @param reason         举报原因
 * @param weight         该举报的风险分贡献
 * @param status         工单状态
 * @param isFalseReport  是否已打标误报（0/1）
 * @param riskScore      被举报帖子的累计风险分
 * @param createdAt      举报时间
 */
public record ReportTicketRow(
        Long reportId,
        Long postId,
        String postTitle,
        String reason,
        Integer weight,
        String status,
        Integer isFalseReport,
        Integer riskScore,
        LocalDateTime createdAt) {
}
