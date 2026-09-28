package com.s2s.server.common.audit;

/**
 * {@code audit_log.operator_role} 列取值枚举——该列四个合法值的唯一落点
 * （DDL {@code V1__init_schema.sql:377}；数据库设计 §3.14）。
 *
 * <p>为什么用枚举而非字符串常量：{@code operator_role} 是 MySQL {@code ENUM} 列，
 * 写入枚举外的值会被 MySQL 以「严格模式下报错、非严格模式下静默存空串」两种方式
 * 处理——后者会让审计行丢失「谁做的」这一最关键字段，且不报任何错。枚举把
 * 「取值合法」变成编译期约束。</p>
 *
 * <p><b>Batch1 已知口径缺口（登记见说明文档 §2.9 DEC-11）</b>：本枚举只有后台四角色，
 * 而 {@code GET /posts/{id}/contact} 的解密留痕由<strong>普通用户</strong>触发
 * （PRD §9.10.1「查看用户脱敏信息」必留审计，可观测 §5 明确「该操作本身就是审计对象」）。
 * 普通用户不属四角色中任何一个，故此类留痕统一以 {@link #SYSTEM}（系统自动留痕）
 * 记录，真实操作人由 {@code operator_id} 承载。若后续评审为 DDL 增加 {@code user} 角色值，
 * 改本枚举 + DDL + 该决策项即可，调用点无需改动。</p>
 */
public enum OperatorRole {

    /** 超级管理员（全部权限，含账号与角色管理）。 */
    SUPER_ADMIN("super_admin"),

    /** 管理员（PRD §9.10.1 四角色模型之一）。 */
    ADMIN("admin"),

    /** 内容审核员（PRD §9.10.1 四角色模型之一）。 */
    AUDITOR("auditor"),

    /** 系统自动动作（无自然人操作人时的留痕角色）。 */
    SYSTEM("system");

    /** 落库值（与 DDL {@code ENUM} 逐字一致，非枚举名）。 */
    private final String dbValue;

    /**
     * 构造角色枚举项。
     *
     * @param dbValue 落库值（DDL {@code ENUM('super_admin','admin','auditor','system')} 之一）
     */
    OperatorRole(String dbValue) {
        this.dbValue = dbValue;
    }

    /**
     * 取落库值。
     *
     * @return {@link String} 与 DDL {@code ENUM} 取值逐字一致的字符串
     */
    public String dbValue() {
        return dbValue;
    }
}
