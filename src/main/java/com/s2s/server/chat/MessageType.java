package com.s2s.server.chat;

/**
 * 消息类型枚举——{@code message.type} 列取值的唯一落点（DDL {@code V30}）。
 *
 * <p>为什么用枚举而不是散落字符串：类型同时决定「是否参与未回复额度」「是否可被
 * 非目标用户看到」「列表摘要取哪套文案」，三处判定若各写一份字面量，新增类型时
 * 必然漏改一处。</p>
 */
public enum MessageType {

    /** 文本消息。 */
    TEXT("text"),

    /** 联系方式申请卡（同会话始终只有一张，状态挂在会话行）。 */
    APPLY("apply"),

    /** 联系方式卡（仅申请人可见，不承载完整号码）。 */
    CONTACT("contact");

    /** 落库值（与 DDL {@code ENUM} 逐字一致）。 */
    private final String dbValue;

    /**
     * 构造消息类型枚举项。
     *
     * @param dbValue 落库值（{@code message.type} 列的合法取值之一）
     */
    MessageType(String dbValue) {
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
