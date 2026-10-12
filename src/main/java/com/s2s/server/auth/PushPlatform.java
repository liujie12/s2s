package com.s2s.server.auth;

/**
 * 推送通道枚举（契约 {@code DevicePlatformEnum}；PRD §6.14；DDL {@code device.push_platform}，[B2-2]）。
 *
 * <p><b>与 {@code device.platform} 是两个维度</b>：{@code device.platform} 是 OS
 * （{@code android/ios}，登录时写），本枚举是**推送通道**（决定服务端走哪家推送服务下发）。
 * 两者同名不同义，不可互相顶替。</p>
 *
 * <p><b>为什么自带线值而不依赖 Jackson 默认枚举映射</b>：与 {@code NotifyType} 同因——
 * 默认按常量名匹配，而契约线值为小写，把线值绑在枚举自身成为唯一口径源。</p>
 *
 * <p><b>FCM 保留但境内不可用</b>：PRD §12 的入参列含 {@code fcm}，故枚举保留该值以对齐契约；
 * 境内无 Google 服务，实际不会收到。</p>
 */
public enum PushPlatform {

    /** Apple 推送（APNs）。 */
    APNS("apns"),

    /** Firebase Cloud Messaging（境内不可用，仅契约对齐）。 */
    FCM("fcm"),

    /** 华为推送。 */
    HW("hw"),

    /** 小米推送。 */
    MI("mi"),

    /** OPPO 推送。 */
    OPPO("oppo"),

    /** vivo 推送。 */
    VIVO("vivo"),

    /** 荣耀推送。 */
    HONOR("honor");

    /** OS 值：iOS。 */
    private static final String OS_IOS = "ios";

    /** OS 值：Android。 */
    private static final String OS_ANDROID = "android";

    private final String wire;

    /**
     * 构造推送通道枚举。
     *
     * @param wire 契约线值（小写）
     */
    PushPlatform(String wire) {
        this.wire = wire;
    }

    /**
     * 取契约线值。
     *
     * @return {@link String} 线值，如 {@code hw}
     */
    public String wire() {
        return wire;
    }

    /**
     * 推导本通道对应的 OS（写 {@code device.platform} 用，仅在该列缺值时兜底）。
     *
     * <p><b>为什么可推导</b>：{@code apns} 是 iOS 专属；其余已接通道
     * （hw/mi/oppo/vivo/honor）都是 Android 生态厂商通道。{@code fcm} 双端都有，
     * 按 Android 处理（境内不可用，不构成实际影响）。</p>
     *
     * <p><b>只作兜底</b>：正常路径 {@code device.platform} 由登录写入（客户端带 OS），
     * 本方法只在「设备行尚不存在」时给出一个合法值以满足该列 {@code NOT NULL}。</p>
     *
     * @return {@link String} {@code ios} 或 {@code android}
     */
    public String osPlatform() {
        return this == APNS ? OS_IOS : OS_ANDROID;
    }

    /**
     * 由契约线值反解枚举。
     *
     * @param wire 契约线值（入参可能为 {@code null}）
     * @return {@link PushPlatform}；{@code null} 入参或不匹配时返回 {@code null}，
     *         由调用方判非法（转 {@code 40001}）
     */
    public static PushPlatform fromWire(String wire) {
        if (wire == null) {
            return null;
        }
        for (PushPlatform candidate : values()) {
            if (candidate.wire.equals(wire)) {
                return candidate;
            }
        }
        return null;
    }
}
