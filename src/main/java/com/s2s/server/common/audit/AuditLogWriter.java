package com.s2s.server.common.audit;

import com.s2s.server.common.audit.mapper.AuditLogMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * {@code audit_log} <b>唯一写入处</b>（编码规范 §1.2 唯一实现处清单；可观测 §5）。
 *
 * <p>职责：把 {@link AuditEntry} 落成一行 {@code audit_log}。所有需要留痕的域
 * （contact / post / category / cert / 后台）一律经本类写入，禁各处自建 insert。</p>
 *
 * <p><b>事务纪律（可观测 §5 原文「审计写入必须与业务操作在同一事务内」）</b>：
 * 本类<b>刻意不加 {@code @Transactional}</b>——它必须加入调用方已开启的事务，
 * 而不是自开一个。若在此处标 {@code REQUIRES_NEW}，会形成「业务回滚但审计已提交」
 * 的假留痕：记录在案的操作其实没发生，比不写审计更难排查。</p>
 *
 * <p>由此推出一条调用侧纪律：<b>凡是「必须留痕」的操作，其 service 方法必须带
 * {@code @Transactional}</b>，否则本次 insert 与业务写入分属两个事务，
 * 审计失败无法回滚业务（出现「操作成功但没留痕」的合规缺口）。</p>
 *
 * <p>写入失败<b>不吞异常</b>：审计是合规举证唯一来源（保留 180 天，
 * 可观测 §5），静默降级为日志等于在无法举证时才发现问题。异常向上抛出，
 * 由调用方事务整体回滚。</p>
 */
@Component
public class AuditLogWriter {

    private static final Logger log = LoggerFactory.getLogger(AuditLogWriter.class);

    /** 审计 Mapper（唯一 insert 出口）。 */
    private final AuditLogMapper auditLogMapper;

    /**
     * 构造审计写入器。
     *
     * @param auditLogMapper 审计 Mapper（由 Spring 注入）
     */
    public AuditLogWriter(AuditLogMapper auditLogMapper) {
        this.auditLogMapper = auditLogMapper;
    }

    /**
     * 写入一条审计留痕（加入调用方事务）。
     *
     * <p>必填字段（operatorId / operatorRole / action / targetType / targetId）
     * 缺失即抛 {@link IllegalArgumentException}：审计行的关键字段为空会让该行
     * 失去举证价值，且 DDL 全为 {@code NOT NULL}——提前在构造期暴露比让 MySQL
     * 报约束错误更可读（范式对齐 {@code AuthContext#setUserId} 的守卫）。</p>
     *
     * @param entry 审计载荷（见 {@link AuditEntry} 的白名单纪律）
     * @throws IllegalArgumentException 任一必填字段为 null / 空串时抛出
     */
    public void write(AuditEntry entry) {
        require(entry.operatorId() != null, "operatorId");
        require(entry.operatorRole() != null, "operatorRole");
        require(entry.action() != null && !entry.action().isBlank(), "action");
        require(entry.targetType() != null && !entry.targetType().isBlank(), "targetType");
        require(entry.targetId() != null, "targetId");

        AuditLogEntity entity = new AuditLogEntity();
        entity.setOperatorId(entry.operatorId());
        entity.setOperatorRole(entry.operatorRole().dbValue());
        entity.setAction(entry.action());
        entity.setTargetType(entry.targetType());
        entity.setTargetId(entry.targetId());
        entity.setBeforeValue(entry.beforeValue());
        entity.setAfterValue(entry.afterValue());
        entity.setReason(entry.reason());
        // created_at 不写：走库内 DEFAULT CURRENT_TIMESTAMP（DDL V1:384），
        // 与「操作时间」语义一致，避免应用时钟与库时钟两套时间源。
        auditLogMapper.insert(entity);

        // 只记「谁对什么做了什么」的结构化三要素；before/after 内容一律不进日志
        // （审计白名单，编码规范 §4.11）。
        log.info("AUDIT_WRITE: operatorId={}, role={}, action={}, target={}:{}",
                entry.operatorId(), entry.operatorRole().dbValue(), entry.action(),
                entry.targetType(), entry.targetId());
    }

    /**
     * 必填字段守卫。
     *
     * @param condition 校验条件
     * @param fieldName 字段名（拼进异常消息，便于定位）
     * @throws IllegalArgumentException 条件不成立时抛出
     */
    private void require(boolean condition, String fieldName) {
        if (!condition) {
            throw new IllegalArgumentException("audit_log 必填字段缺失: " + fieldName);
        }
    }
}
