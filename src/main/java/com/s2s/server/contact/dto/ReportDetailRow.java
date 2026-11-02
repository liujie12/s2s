package com.s2s.server.contact.dto;

import java.time.LocalDateTime;

/**
 * 举报工单详情行（contact 域内部出参，SQL 结果映射；供 {@code ContactService} 解析）。
 *
 * <p>与 {@link ReportTicketRow} 的差别：本行面向「单条复核」，故带上
 * {@code description}（用户补充说明）、{@code evidenceJson}（凭证 media_ids 的 JSON 文本）
 * 与处理结果三列（{@code status}/{@code handledAt}/{@code handlerId}）。</p>
 *
 * @param reportId       举报 ID
 * @param postId         被举报帖子 ID
 * @param postTitle      被举报帖子标题
 * @param reason         举报原因
 * @param description    举报补充说明（契约字段名 remark）
 * @param evidenceJson   凭证 media_ids 的 JSON 文本（可为 null）
 * @param weight         该举报的风险分贡献
 * @param status         工单状态
 * @param isFalseReport  是否已打标误报（0/1）
 * @param riskScore      被举报帖子的累计风险分
 * @param createdAt      举报时间
 * @param handledAt      处理时间（未处理为 null）
 * @param handlerId      处理人 admin_user.id（未处理为 null）
 */
public record ReportDetailRow(
        Long reportId,
        Long postId,
        String postTitle,
        String reason,
        String description,
        String evidenceJson,
        Integer weight,
        String status,
        Integer isFalseReport,
        Integer riskScore,
        LocalDateTime createdAt,
        LocalDateTime handledAt,
        Long handlerId) {
}
