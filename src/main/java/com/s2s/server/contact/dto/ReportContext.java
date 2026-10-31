package com.s2s.server.contact.dto;

/**
 * 举报工单定位信息（U7；后台复核会话正文用，contact 域内部出参）。
 *
 * <p>只承载「定位一方会话所需的最小集合」：帖子 + 举报人 + 被举报人 + 原因。
 * 描述与凭证不在此列——复核正文只需要找到那条会话，多回内容等于让举报材料
 * 多一个出口。</p>
 *
 * @param reportId       举报 ID
 * @param postId         举报关联的帖子 ID（会话锚点）
 * @param reporterId     举报人 user_id（会话双方之一）
 * @param reportedUserId 被举报人 user_id（会话双方之二）
 * @param reason         举报原因（{@code report.reason} 枚举值）
 */
public record ReportContext(
        Long reportId,
        Long postId,
        Long reporterId,
        Long reportedUserId,
        String reason) {
}
