package com.s2s.server.contact.dto;

import java.time.LocalDateTime;
import java.util.List;

/**
 * 举报工单详情（contact 域出参；admin 域据此组装凭证签名 URL）。
 *
 * <p><b>为什么不在本域签 URL</b>：签名是媒体域的能力（OSS 地址只有 media 域知道怎么拼），
 * contact 域只负责把「举报里存了什么」如实交出去。凭证 {@code evidence} 在本对象里仍是
 * media_id 字符串，URL 的生成与「谁在看」的审计留在后台入口，便于把敏感取图收敛在一处。</p>
 *
 * @param reportId       举报 ID
 * @param postId         被举报帖子 ID
 * @param postTitle      被举报帖子标题
 * @param reason         举报原因
 * @param description    举报补充说明（契约字段名 remark；可空）
 * @param evidence       凭证 media_ids（无凭证时为空列表，不返回 null）
 * @param weight         该举报的风险分贡献
 * @param status         工单状态
 * @param isFalseReport  是否已打标误报（0/1）
 * @param riskScore      被举报帖子的累计风险分
 * @param createdAt      举报时间
 * @param handledAt      处理时间（未处理为 null）
 * @param handlerId      处理人 admin_user.id（未处理为 null）
 */
public record ReportDetail(
        Long reportId,
        Long postId,
        String postTitle,
        String reason,
        String description,
        List<String> evidence,
        Integer weight,
        String status,
        Integer isFalseReport,
        Integer riskScore,
        LocalDateTime createdAt,
        LocalDateTime handledAt,
        Long handlerId) {
}
