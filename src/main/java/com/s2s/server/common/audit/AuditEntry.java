package com.s2s.server.common.audit;

/**
 * 审计留痕写入载荷（{@link AuditLogWriter#write(AuditEntry)} 的入参）。
 *
 * <p>为什么用 record 而非逐参数方法：{@code audit_log} 有 7 个可变字段
 * （operator/role/action/target/before/after/reason），逐参数方法调用点会出现
 * 「七个位置参数连着写」的形态——顺序写错（如把 targetType 与 action 写反）
 * 编译期无法发现，且审计行一旦写错就失去举证价值。record 强制具名。</p>
 *
 * <p><b>{@code beforeValue}/{@code afterValue} 的白名单纪律</b>（编码规范 §4.11）：
 * 只准放非敏感字段的 JSON 文本，禁放 {@code phone}/{@code real_name}/
 * {@code id_card}/{@code contact_value}/{@code *_enc}/{@code *_hash}。绝大部分
 * 留痕场景两者留 {@code null} 即可——审计要回答的是「谁在何时对哪个对象做了什么」，
 * 不是「内容是什么」；把内容抄进审计等于给敏感数据开了第二个出口。</p>
 *
 * @param operatorId  操作人 user_id（必填，非 null）
 * @param operatorRole 操作人角色（必填，非 null）
 * @param action      动作标识（必填，如 {@code contact.view} / {@code report.create}）
 * @param targetType  目标对象类型（必填，如 {@code post}）
 * @param targetId    目标对象 ID（必填，非 null）
 * @param beforeValue 变更前值 JSON（可空，默认 null）
 * @param afterValue  变更后值 JSON（可空，默认 null）
 * @param reason      操作理由（可空，下架与驳回场景强制填写——PRD §9.10.1）
 */
public record AuditEntry(
        Long operatorId,
        OperatorRole operatorRole,
        String action,
        String targetType,
        Long targetId,
        String beforeValue,
        String afterValue,
        String reason) {

    /**
     * 构造「无变更前后值、无理由」的最小留痕载荷（读类审计的常规形态）。
     *
     * <p>提取为命名工厂的理由：{@code contact.view} 与 {@code report.create} 两处
     * 调用都需要「末尾三个参数全 null」的形态，逐个写 {@code null, null, null}
     * 在调用点读不出含义，且第二次出现即属编码规范 §1.1 要求抽提的重复逻辑。</p>
     *
     * @param operatorId   操作人 user_id
     * @param operatorRole 操作人角色
     * @param action       动作标识
     * @param targetType   目标对象类型
     * @param targetId     目标对象 ID
     * @return {@link AuditEntry} 前后值与理由均为 {@code null} 的载荷
     */
    public static AuditEntry minimal(Long operatorId, OperatorRole operatorRole, String action,
            String targetType, Long targetId) {
        return new AuditEntry(operatorId, operatorRole, action, targetType, targetId, null, null, null);
    }
}
