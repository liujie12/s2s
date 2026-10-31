package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 联系方式申请卡状态（V30 / 计划 U6；openapi 申请 / 审批 / 查询三个接口共用响应）。
 *
 * <p><b>中转页只读这一份状态</b>：{@code can_view_contact} 决定「查看完整号码」是否可点，
 * {@code can_apply} 与 {@code reapply_at} 决定「申请」入口是否置灰并显示倒计时（R21a）。
 * 完整号码不在此返回，仍只由 {@code GET /posts/{id}/contact} 给出（R22）。</p>
 *
 * @param conversationId 会话 ID
 * @param applyRequired  该帖是否设置了「查看联系方式需申请」（R19）
 * @param applyStatus    卡片状态（none/pending/approved/rejected）
 * @param owner          当前用户是否为帖子发布者（发布者审批，不申请）
 * @param canApply       当前用户此刻能否提交申请（非发布者、需申请、且不在冷却 / 重申窗口内）
 * @param canViewContact 当前用户此刻能否取号（发布者本人 / 无需申请 / 已同意）
 * @param reapplyAt      下次可再次申请的时刻（UTC；待审批满重申窗口或被拒满冷却期后）；
 *                       当前即可申请或不可申请时为 null
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ApplyStateResponse(
        Long conversationId,
        boolean applyRequired,
        String applyStatus,
        boolean owner,
        boolean canApply,
        boolean canViewContact,
        Instant reapplyAt) {
}
