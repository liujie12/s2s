package com.s2s.server.contact;

/**
 * 举报原因枚举——{@code report.reason} 列取值的唯一落点
 * （DDL {@code V1__init_schema.sql:266}；openapi {@code POST /posts/{id}/report} 的
 * {@code reason} enum；详设 §5.5.2「与 {@code report.reason} 列<b>严格一致</b>」）。
 *
 * <p><b>为什么必须用枚举校验而不是「非空即可」</b>：{@code reason} 是 MySQL
 * {@code ENUM} 列，写入枚举外的值在严格模式下报错（表现为 50001，把客户端的参数
 * 错误伪装成服务端故障），在非严格模式下则静默存空串（举报记录失去原因，
 * 永远无法进入 §9.10.3 的权重累计）。校验放在落库前，两种坏结果都避免。</p>
 *
 * <p>客户端传 {@code reason} 非法值属参数错误，回 {@code 40001}（客户端按
 * 「修参重试、不提示用户」处理，编码规范 §4.12）。</p>
 */
public enum ReportReason {

    /** 不实信息。 */
    FALSE_INFO("false_info"),

    /** 诈骗。 */
    FRAUD("fraud"),

    /** 违规类目。 */
    WRONG_CATEGORY("wrong_category"),

    /** 骚扰。 */
    HARASSMENT("harassment"),

    /** 其他。 */
    OTHER("other");

    /** 落库值（与 DDL {@code ENUM} 逐字一致）。 */
    private final String dbValue;

    /**
     * 构造举报原因枚举项。
     *
     * @param dbValue 落库值（{@code report.reason} 列的合法取值之一）
     */
    ReportReason(String dbValue) {
        this.dbValue = dbValue;
    }

    /**
     * 取落库值。
     *
     * @return {@link String} 与 DDL {@code ENUM} 一致的字符串
     */
    public String dbValue() {
        return dbValue;
    }

    /**
     * 判断入参是否为契约声明的合法举报原因。
     *
     * @param apiValue 客户端传入的 {@code reason} 原值（可能为 null）
     * @return boolean；五值之一为 {@code true}，其余（含 null）为 {@code false}
     */
    public static boolean isValid(String apiValue) {
        for (ReportReason reason : values()) {
            if (reason.dbValue.equals(apiValue)) {
                return true;
            }
        }
        return false;
    }
}
