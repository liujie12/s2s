package com.s2s.server.common.constants;

import java.time.Duration;

/**
 * 72h 临时类目快速验证通道（PRD §9.10.2）的**阈值唯一落点**。
 *
 * <p>PRD 明文给定三条量：验证窗口 **72h**、达标线 **发布数 ≥3** 且 **被联系数 ≥5**。
 * 本类承载其数值与由此推出的取数窗口，禁在业务代码写死数字（编码规范 §3.1）。</p>
 *
 * <p>定时任务扫描周期 PRD 未定义，取**实现默认值**（同 {@code NfrAdmin} 的既有做法），
 * 待需求侧评审后如有正式口径，改本类一处即可。</p>
 */
public final class NfrTempCategory {

    /**
     * 工具类：禁止实例化。
     */
    private NfrTempCategory() {
        throw new AssertionError("NfrTempCategory 是常量类，不可实例化");
    }

    /** 验证窗口：72 小时（PRD §9.10.2「72h 自动下线」）。 */
    public static final Duration VALIDATION_WINDOW = Duration.ofHours(72);

    /** 达标线：窗口内发布数下限（PRD §9.10.2「发布数 ≥3」）。 */
    public static final int PROMOTE_MIN_PUBLISH = 3;

    /** 达标线：窗口内被联系数下限（PRD §9.10.2「被联系数 ≥5」）。 */
    public static final int PROMOTE_MIN_CONTACT = 5;

    /**
     * 到期结算任务的扫描周期（秒）。
     *
     * <p>实现默认值（PRD 未定义）：取 300s（5 分钟）—— 相对 72h 窗口，5 分钟的结算延迟
     * 对「临时类目体验」无感，同时避免高频空扫。</p>
     */
    public static final long EXPIRE_SCAN_INTERVAL_SECONDS = 300L;
}
