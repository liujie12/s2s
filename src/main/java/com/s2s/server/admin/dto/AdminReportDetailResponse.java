package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 举报工单详情出参（PRD §9.10.1 ④；{@code GET /admin/reports/{id}}）。
 *
 * <p><b>为什么要单独一个详情接口</b>：列表只有「谁因为哪类原因被举报、累计多少分」，
 * 足够排序与批量处理，但不足以判断「这条举报是否成立」。复核需要用户写的补充说明
 * （{@code description}）与凭证图（{@code evidence_urls}），二者只在详情里出现，
 * 避免队列响应变重、也避免把复核材料在列表页无差别铺开。</p>
 *
 * <p>{@code evidence_urls} 是限时签名 URL，不是 media_id：后台页面直接可渲染，
 * 且不用再调一次取图接口。失效/缺失的凭证会被过滤，不阻断整条工单的查看。</p>
 *
 * @param reportId      举报 ID
 * @param postId        被举报帖子 ID
 * @param postTitle     被举报帖子标题
 * @param reason        举报原因
 * @param description   举报补充说明（契约字段名 remark；可空）
 * @param evidenceUrls  凭证图签名 URL（无凭证或图已失效时为空数组）
 * @param weight        该举报的风险分贡献
 * @param status        工单状态
 * @param isFalseReport 是否已打标误报（0/1）
 * @param riskScore     被举报帖子的累计风险分
 * @param createdAt     举报时间
 * @param handledAt     处理时间（未处理为 null）
 * @param handlerId     处理人 admin_user.id（未处理为 null）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminReportDetailResponse(
        Long reportId,
        Long postId,
        String postTitle,
        String reason,
        String description,
        List<String> evidenceUrls,
        Integer weight,
        String status,
        Integer isFalseReport,
        Integer riskScore,
        Instant createdAt,
        Instant handledAt,
        Long handlerId) {
}
