package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.ErrorCode;

/**
 * 限频键轨标识枚举——详设 §3.4 键表 11 行的逐行映射，充当
 * 「{@code @RateLimit} 注解声明 → {@link RateLimitThresholds} 常量取值 → U4 键拼装」
 * 的编译期桥（计划 [122] 架构验证 D7：注解属性类型须编译期可解析）。
 *
 * <p>每轨持有 1..n 个 {@link WindowRule}（阈值/窗口秒/超限码三元组），三元组逐值
 * 引用 {@code RateLimitThresholds} 常量——本枚举不出现任何数字（对账断言见
 * {@code RateLimitTrackTest}）。多窗口轨（短信·手机号）持有 3 个规则；其余单轨 1 个。</p>
 *
 * <p><b>本条目（U1）边界</b>：只落标识与阈值绑定，不做键拼装（{@code RateLimitKeys}
 * 归 U4）、不做设备头格式校验（{@code X-Device-Id} 入键前校验归 U4，KTD14）、
 * 不做计数与超限判定（{@code RateLimiter} 归 U4）。</p>
 *
 * <p>出处：详设 §3.4（键表 11 行原文）、§3.1（横切链位次）。</p>
 */
public enum RateLimitTrack {

    /**
     * 行 1 · 短信发送（手机号维度，渠道级）：键形 {@code rl:sms:phone:{phone}:{1m|1h|1d}}，
     * 1/min、5/h、10/d → 42905。多窗口轨：三个规则同时生效，任一超限即拒。
     */
    SMS_PHONE(
            new WindowRule(RateLimitThresholds.SMS_PHONE_LIMIT_PER_MINUTE,
                    RateLimitThresholds.WINDOW_MINUTE_SECONDS, RateLimitThresholds.SMS_OVERFLOW),
            new WindowRule(RateLimitThresholds.SMS_PHONE_LIMIT_PER_HOUR,
                    RateLimitThresholds.WINDOW_HOUR_SECONDS, RateLimitThresholds.SMS_OVERFLOW),
            new WindowRule(RateLimitThresholds.SMS_PHONE_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS, RateLimitThresholds.SMS_OVERFLOW)),

    /**
     * 行 2 · 短信发送（IP 维度，渠道级）：键形 {@code rl:sms:ip:{ip}:1h}，20/h → 42905。
     * 未登录无 userId，渠道级保留手机号/IP 维度（详设 §3.4 纪律 2）。
     */
    SMS_IP(
            new WindowRule(RateLimitThresholds.SMS_IP_LIMIT_PER_HOUR,
                    RateLimitThresholds.WINDOW_HOUR_SECONDS, RateLimitThresholds.SMS_OVERFLOW)),

    /**
     * 行 3 · 登录失败锁定（渠道级）：键形 {@code rl:login:fail:{phone}}，
     * 5 次锁 15min → 40105。窗口秒取锁定时长（计数窗与锁定窗同为 15 分钟，
     * 详设 §3.4 原文「5 次 → 锁 15min」）。
     */
    LOGIN_FAIL(
            new WindowRule(RateLimitThresholds.LOGIN_FAIL_THRESHOLD,
                    RateLimitThresholds.LOGIN_FAIL_LOCK_SECONDS,
                    RateLimitThresholds.LOGIN_FAIL_OVERFLOW)),

    /**
     * 行 4 · 联系方式拉取（账号维度，账号级）：键形 {@code rl:contact:uid:{userId}:1d}，
     * 30/d → 42902。账号级风控一律 user_id（详设 §3.4 纪律 1），自然日窗口（KTD6）。
     */
    CONTACT_UID(
            new WindowRule(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS, RateLimitThresholds.CONTACT_OVERFLOW)),

    /**
     * 行 5 · 联系方式拉取（设备辅助维度，账号级辅助）：键形
     * {@code rl:contact:dev:{fingerprint}:1d}，30/d → 42902。
     */
    CONTACT_DEV(
            new WindowRule(RateLimitThresholds.CONTACT_DEV_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS, RateLimitThresholds.CONTACT_OVERFLOW)),

    /**
     * 行 6 · 联系方式拉取（IP 渠道维度，渠道级）：键形 {@code rl:contact:ip:{ip}:1d}，
     * 100/d → 42902。响应不区分命中维度（风控信息不外泄，编码规范 §4.7）。
     */
    CONTACT_IP(
            new WindowRule(RateLimitThresholds.CONTACT_IP_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS, RateLimitThresholds.CONTACT_OVERFLOW)),

    /**
     * 行 7 · 联系熔断（账号级）：计数键 {@code rl:contact:burst:{userId}:1m}，
     * 1min ≥10 次 → 42903 当日冻结。冻结标记 {@code fz:contact:{userId}:{date}}
     * 的写入/判定归 U4（键拼装）与 [128]，本轨只承载计数三元组。
     */
    CONTACT_BURST(
            new WindowRule(RateLimitThresholds.CONTACT_BURST_LIMIT_PER_MINUTE,
                    RateLimitThresholds.WINDOW_MINUTE_SECONDS,
                    RateLimitThresholds.CONTACT_BURST_OVERFLOW)),

    /**
     * 行 8 · 举报频次（账号级）：键形 {@code rl:report:uid:{userId}:1d}，
     * 阈值详设原文「熔断同上」（数值沿 CONTACT_BURST 的 10 次、窗口取键尾 :1d 自然日）
     * → 42903。解读依据见 {@code RateLimitThresholds#REPORT_UID_LIMIT_PER_DAY} 注释。
     */
    REPORT_UID(
            new WindowRule(RateLimitThresholds.REPORT_UID_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS, RateLimitThresholds.REPORT_OVERFLOW)),

    /**
     * 行 9 · 埋点上报（账号级）：键形 {@code rl:track:uid:{userId}:1m}，
     * 60 请求/min → 42906（唯一不向用户呈现的错误码，客户端静默退回队列）。
     * 强制登录态，user_id 只取登录态（编码规范 §4.7）。
     */
    TRACK_UID(
            new WindowRule(RateLimitThresholds.TRACK_UID_LIMIT_PER_MINUTE,
                    RateLimitThresholds.WINDOW_MINUTE_SECONDS, RateLimitThresholds.TRACK_OVERFLOW)),

    /**
     * 行 10 · 未登录详情浏览（设备维度，无账号维）：键形
     * {@code rl:guestdetail:dev:{deviceId}:1d}，30/d → 42907。唯一没有账号维的轨
     * （详设 §3.4 特殊性 2）；仅未登录请求生效——判定点在鉴权上下文之后（U7）。
     */
    GUEST_DETAIL_DEV(
            new WindowRule(RateLimitThresholds.GUEST_DETAIL_DEV_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS,
                    RateLimitThresholds.GUEST_DETAIL_OVERFLOW)),

    /**
     * 行 11 · 未登录详情浏览（IP 渠道维度，渠道级）：键形
     * {@code rl:guestdetail:ip:{ip}:1d}，100/d → 42907。与设备轨同码、
     * 阈值沿用联系方式 IP 档（详设明文「不新造数字」）。
     */
    GUEST_DETAIL_IP(
            new WindowRule(RateLimitThresholds.GUEST_DETAIL_IP_LIMIT_PER_DAY,
                    RateLimitThresholds.WINDOW_DAY_SECONDS,
                    RateLimitThresholds.GUEST_DETAIL_OVERFLOW));

    private final WindowRule[] rules;

    /**
     * 构造键轨：绑定 1..n 个窗口规则（多窗口轨如 SMS_PHONE 传 3 个）。
     *
     * @param rules 该轨的窗口规则集合（逐值引用 RateLimitThresholds 常量）
     */
    RateLimitTrack(WindowRule... rules) {
        this.rules = rules.clone();
    }

    /**
     * 取该轨的窗口规则集合。
     *
     * @return {@link WindowRule} 数组副本（防御性拷贝，调用方改副本不影响轨定义）；
     *         长度 ≥1，多窗口轨（短信·手机号）为 3
     */
    public WindowRule[] rules() {
        return rules.clone();
    }

    /**
     * 单条限频窗口规则（阈值 / 窗口秒 / 超限码三元组）。
     *
     * <p>承载形态：record（Java 21、无 Lombok 纪律）；三个分量均引用
     * {@link RateLimitThresholds} 常量构造，实例只存在于 {@link RateLimitTrack}
     * 枚举常量定义处——业务代码禁自行 new（三元组唯一落点在枚举绑定处）。</p>
     *
     * @param limit        窗口内允许的最大计数（阈值）
     * @param windowSeconds 窗口长度（秒）；自然日语义（:1d 轨）由 U4 键尾日期片承载，
     *                     本字段是秒数基准
     * @param overflowCode 超限错误码（{@link ErrorCode}，needRetryAfter 码抛出时
     *                     必须携带剩余秒数）
     */
    public record WindowRule(int limit, long windowSeconds, ErrorCode overflowCode) {
    }
}
