package com.s2s.server.notify;

/**
 * 通知类型（契约 {@code Notification.type} 的三值枚举；详设 §5.6；DDL {@code notification.type}）。
 *
 * <p><b>为什么自带线值而不依赖 Jackson 默认枚举映射</b>：与 {@code TrackEventItem.EventName}
 * 同因——默认按常量名（{@code SYSTEM}）匹配，而契约线值为小写（{@code system}）。把线值
 * 绑在枚举自身成为唯一口径源，避免「SQL 里判一套、Java 里判另一套」。</p>
 *
 * <p><b>本枚举只作查询筛选白名单</b>：{@code type} 是可选入参，非法值由调用方转
 * {@code 40001}（对齐 {@code MapService} 对枚举非法值的既有处置）。</p>
 */
public enum NotifyType {

    /** 系统通知（实名认证通过、资质通过、违规下架、版本更新）。 */
    SYSTEM("system"),

    /** 互动通知（"你的发布被联系了"、"有人发布了对应资源"）。 */
    INTERACTION("interaction"),

    /** 认证通知（审核进度、年审提醒）。 */
    CERT("cert");

    private final String wire;

    /**
     * 构造通知类型枚举。
     *
     * @param wire 契约线值（小写）
     */
    NotifyType(String wire) {
        this.wire = wire;
    }

    /**
     * 取契约线值。
     *
     * @return {@link String} 线值，如 {@code interaction}
     */
    public String wire() {
        return wire;
    }

    /**
     * 由契约线值反解枚举。
     *
     * @param wire 契约线值（入参可能为 {@code null}）
     * @return {@link NotifyType}；{@code null} 入参返回 {@code null}（表示「不筛选」），
     *         非空但不匹配时返回 {@code null} 由调用方判非法
     */
    public static NotifyType fromWire(String wire) {
        if (wire == null) {
            return null;
        }
        for (NotifyType candidate : values()) {
            if (candidate.wire.equals(wire)) {
                return candidate;
            }
        }
        return null;
    }
}
