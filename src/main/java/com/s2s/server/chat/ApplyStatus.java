package com.s2s.server.chat;

/**
 * 联系方式申请卡状态枚举——{@code conversation.apply_status} 列取值的唯一落点（DDL {@code V30}）。
 *
 * <p>状态挂在会话行而不是卡片行（KTD2）：同一会话始终只有一张申请卡，
 * 被拒后满冷却天数再次提交仍复用同一张卡，只把状态推回 {@link #PENDING}。</p>
 */
public enum ApplyStatus {

    /** 该帖子无需申请，或本会话从未提交过申请。 */
    NONE("none"),

    /** 已提交、待发布者审批。 */
    PENDING("pending"),

    /** 发布者已同意，申请人可取号。 */
    APPROVED("approved"),

    /** 发布者已拒绝；冷却期后可再次提交。 */
    REJECTED("rejected");

    /** 落库值（与 DDL {@code ENUM} 逐字一致）。 */
    private final String dbValue;

    /**
     * 构造申请状态枚举项。
     *
     * @param dbValue 落库值（{@code conversation.apply_status} 列的合法取值之一）
     */
    ApplyStatus(String dbValue) {
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
}
