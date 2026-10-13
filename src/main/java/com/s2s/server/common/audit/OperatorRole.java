package com.s2s.server.common.audit;

/**
 * {@code audit_log.operator_role} 列取值枚举——该列合法值的唯一落点
 * （DDL {@code V1__init_schema.sql:377}、增量 {@code V8__audit_operator_role_user.sql}；
 * 数据库设计 §3.14）。
 *
 * <p>为什么用枚举而非字符串常量：{@code operator_role} 是 MySQL {@code ENUM} 列，
 * 写入枚举外的值会被 MySQL 以「严格模式下报错、非严格模式下静默存空串」两种方式
 * 处理——后者会让审计行丢失「谁做的」这一最关键字段，且不报任何错。枚举把
 * 「取值合法」变成编译期约束。</p>
 *
 * <p><b>口径沿革（DEC-11，[147] 已落地）</b>：本枚举原只有后台四角色，而
 * {@code GET /posts/{id}/contact} 的解密留痕由<strong>普通用户</strong>触发
 * （PRD §9.10.1「查看用户脱敏信息」必留审计，可观测 §5 明确「该操作本身就是审计对象」）。
 * 普通用户不属四角色中任何一个，早期以 {@link #SYSTEM}（系统自动留痕）兜底、真实操作人
 * 由 {@code operator_id} 承载。DEC-11 已裁定改为<strong>新增 {@link #USER} 枚举值</strong>
 * （不再用 system 兜底），落地 = 本枚举 + DDL {@code V8}，调用点不变。</p>
 */
public enum OperatorRole {

    /** 超级管理员（全部权限，含账号与角色管理）。 */
    SUPER_ADMIN("super_admin"),

    /** 管理员（历史值：PRD 四角色模型无对应角色，保留不删、当前无消费方）。 */
    ADMIN("admin"),

    /** 内容审核员（PRD §9.10.1 四角色模型之一）。 */
    AUDITOR("auditor"),

    /** 运营专员（PRD §9.10.1 四角色模型之一；[153] DEC 扩充）。 */
    OPERATOR("operator"),

    /** 算法运营（PRD §9.10.1 四角色模型之一；[153] DEC 扩充）。 */
    ALGO("algo"),

    /** 系统自动动作（无自然人操作人时的留痕角色）。 */
    SYSTEM("system"),

    /** 普通用户（用户触发的解密留痕专用；DEC-11 新增，非后台角色）。 */
    USER("user");

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

    /**
     * 判断是否「后台四角色」之一（PRD §9.10.1：超级管理员/内容审核员/运营专员/算法运营）。
     *
     * <p>用于后台账号角色（{@code admin_user.role}）的合法性约束——{@link #ADMIN}（历史值）、
     * {@link #SYSTEM}、{@link #USER} 均**不是**后台可分配角色。</p>
     *
     * @return boolean；{@code true} 表示可作为后台账号角色
     */
    public boolean isAdminRole() {
        return this == SUPER_ADMIN || this == AUDITOR || this == OPERATOR || this == ALGO;
    }

    /**
     * 按落库值反查枚举（{@code dbValue} → 枚举项）。
     *
     * @param dbValue 落库值字符串（如 {@code super_admin}）
     * @return {@link OperatorRole} 匹配项；无匹配返回 {@code null}（调用方自行判定非法）
     */
    public static OperatorRole fromDbValue(String dbValue) {
        for (OperatorRole role : values()) {
            if (role.dbValue.equals(dbValue)) {
                return role;
            }
        }
        return null;
    }
}
