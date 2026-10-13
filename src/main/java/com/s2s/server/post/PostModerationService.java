package com.s2s.server.post;

import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.mapper.PostMapper;
import org.springframework.stereotype.Service;

/**
 * 帖子治理服务（[153] B2-5 ④；PRD §9.10.3「举报分级响应引擎」的 post 侧落点）。
 *
 * <p>为什么单独立类而不塞进 {@link PostService}：本类只承载「举报风险分累计」与
 * 「审核下架」两条<b>治理</b>动作，调用方是 contact 域（举报链）与 admin 域（工单处理），
 * 与「用户自己发布/改状态」的 {@link PostService} 属不同权限上下文 —— 混在一起会出现
 * 「谁都能调审核下架」的越权面。</p>
 *
 * <p><b>阈值不落在本类</b>：风险分阈值（PRD §9.10.3 累计 ≥60 自动下架）由调用方
 * （contact 域的 {@code ReportRiskScore}）判定，本类只做「加多少分」「是否下架」的机械执行，
 * 避免同一阈值在两端各写一份。</p>
 *
 * <p><b>审计</b>：审核下架属「必留操作」，由调用方在同一事务内触发本类写入
 * （{@code audit_log} 归属真实操作人）。</p>
 */
@Service
public class PostModerationService {

    /** 审计动作：审核下架。 */
    public static final String ACTION_AUDIT_TAKEDOWN = "post.audit_takedown";

    /** 审计目标类型：帖子。 */
    static final String TARGET_POST = "post";

    /** post 表 Mapper（本域自有）。 */
    private final PostMapper postMapper;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造帖子治理服务。
     *
     * @param postMapper     post 表 Mapper
     * @param auditLogWriter 审计写入器
     */
    public PostModerationService(PostMapper postMapper, AuditLogWriter auditLogWriter) {
        this.postMapper = postMapper;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 累加举报风险分（增量可正可负，用于「新增举报」与「打标误报回撤」）。
     *
     * <p>分数下限截断到 0：误报回撤不应把风险分压成负数（负数会让后续举报的累计
     * 需要更多次才触发阈值，等于给被举报方打折）。</p>
     *
     * @param postId 帖子 ID
     * @param delta  风险分增量（正=累加，负=回撤）
     * @return int 累加后的风险分；帖子不存在时返回 0
     */
    public int applyRiskDelta(long postId, int delta) {
        PostEntity post = postMapper.selectById(postId);
        if (post == null) {
            return 0;
        }
        int current = post.getRiskScore() == null ? 0 : post.getRiskScore();
        int next = Math.max(0, current + delta);
        PostEntity patch = new PostEntity();
        patch.setId(postId);
        patch.setRiskScore(next);
        postMapper.updateById(patch);
        return next;
    }

    /**
     * 审核下架（进入 {@code archived} + {@code status_reason=2 审核下架}）。
     *
     * <p>幂等：仅当帖子当前为 {@code active} 时改（已下架/已过期的不覆盖其归因，
     * 否则「到期」会被运营动作改写成「审核下架」，用户看到的文案就错了）。</p>
     *
     * @param postId     帖子 ID
     * @param operatorId 操作人 ID（审计用；自动触发时传发布者无关的系统侧语义值）
     * @param role       操作人角色（审计用）
     * @return boolean；{@code true} 表示本次确实执行了下架
     */
    public boolean auditTakedown(long postId, Long operatorId, OperatorRole role) {
        PostEntity post = postMapper.selectById(postId);
        if (post == null || !PostStatus.DB_ACTIVE.equals(post.getStatus())) {
            return false;
        }
        PostEntity patch = new PostEntity();
        patch.setId(postId);
        patch.setStatus(PostStatus.DB_ARCHIVED);
        patch.setStatusReason(PostStatus.REASON_AUDIT_TAKEDOWN);
        postMapper.updateById(patch);

        auditLogWriter.write(new AuditEntry(operatorId, role, ACTION_AUDIT_TAKEDOWN,
                TARGET_POST, postId, null, "{\"statusReason\":2}", null));
        return true;
    }
}
