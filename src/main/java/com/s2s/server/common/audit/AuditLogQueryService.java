package com.s2s.server.common.audit;

import com.s2s.server.common.audit.dto.AuditLogFilter;
import com.s2s.server.common.audit.dto.AuditLogItem;
import com.s2s.server.common.audit.dto.AuditLogPage;
import com.s2s.server.common.audit.mapper.AuditLogMapper;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 审计查询服务（[153] B2-5）：{@code audit_log} 的<b>读路径唯一实现处</b>
 * （写路径是 {@link AuditLogWriter}）。
 *
 * <p>归属：{@code audit_log} 属 common（audit）域，故读能力落本域，供后台（admin 域）
 * 经服务接口调用 —— 依架构 §3「功能域互相调用走对方 service 接口、不允许跨域访问
 * 对方 mapper」。</p>
 *
 * <p><b>权限不在此</b>：本服务是纯查询，不判角色。RBAC（仅超级管理员可查，PRD §9.10.1）
 * 由调用方 {@code AdminAuditService} 在进入本服务前完成 —— 把权限判定与数据访问分开，
 * 避免「换个调用方就绕过」。分页参数经调用方归一，本服务只做「过滤 + 分页 + 映射」。</p>
 */
@Service
public class AuditLogQueryService {

    /** 审计 Mapper（查询方法落在其 XML）。 */
    private final AuditLogMapper auditLogMapper;

    /**
     * 构造审计查询服务。
     *
     * @param auditLogMapper 审计 Mapper
     */
    public AuditLogQueryService(AuditLogMapper auditLogMapper) {
        this.auditLogMapper = auditLogMapper;
    }

    /**
     * 按过滤条件分页查询审计留痕。
     *
     * @param filter 过滤条件（含 limit/offset，由调用方归一与校验）
     * @param page   页码（1 起，仅用于回填出参）
     * @param pageSize 每页条数（仅用于回填出参）
     * @return {@link AuditLogPage} 当前页条目 + 总数 + 分页元信息
     */
    public AuditLogPage query(AuditLogFilter filter, int page, int pageSize) {
        long total = auditLogMapper.countByFilter(filter);
        List<AuditLogItem> items = auditLogMapper.selectPageByFilter(filter).stream()
                .map(AuditLogQueryService::toItem)
                .toList();
        return new AuditLogPage(items, total, page, pageSize);
    }

    /**
     * 实体 → 出参 DTO。
     *
     * @param entity 审计行
     * @return {@link AuditLogItem} 出参
     */
    private static AuditLogItem toItem(AuditLogEntity entity) {
        return new AuditLogItem(
                entity.getId(),
                entity.getOperatorId(),
                entity.getOperatorRole(),
                entity.getAction(),
                entity.getTargetType(),
                entity.getTargetId(),
                entity.getBeforeValue(),
                entity.getAfterValue(),
                entity.getReason(),
                entity.getCreatedAt() == null ? null : entity.getCreatedAt().toInstant(ZoneOffset.UTC));
    }
}
