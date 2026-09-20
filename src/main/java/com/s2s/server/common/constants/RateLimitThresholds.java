package com.s2s.server.common.constants;

import java.time.ZoneId;

import com.s2s.server.common.error.ErrorCode;

/**
 * 限频阈值唯一真源——<b>服务端单端正源</b>，逐值抄录自详设 §3.4「限频键设计」11 行键表
 * （计划 [122] KTD11）。
 *
 * <p><b>为什么不是 Dart 镜像（例外登记）</b>：Dart 真源 {@code lib/nfr_constants.dart}
 * 无 {@code NfrRateLimit} 类——客户端被禁止本地预测剩余次数（编码规范 §5.4：限频文案
 * 不承诺剩余次数、42907 无次数字段禁本地累计预测），阈值在 Dart 端无消费方，故本类
 * 直接以详设 §3.4 表格为真源抄录。此例外按编码规范 §3.1 登记（KTD11），是唯一允许
 * 「Java 独有 NFR 数字常量」的类。</p>
 *
 * <p><b>值域分工</b>：本类只存值（阈值 / 窗口秒 / 超限码三元组 + 时区），不做键拼装——
 * Redis 键形（{@code rl:sms:phone:{phone}:1m} 等，含 KTD6 的 {@code :1d} 轨键尾日期片）
 * 归 {@code RateLimitKeys}（[122] U4）唯一拼装，符合规范 §1.2「RateLimiter + RateLimitKeys
 * 是唯一限频计数与键命名处」。超限码一律引用 {@link ErrorCode} 枚举（错误码唯一口径源
 * PRD §12.5），本类不出现裸数字错误码。</p>
 *
 * <p><b>改动纪律</b>：本类任一常量改动，必须同时改详设 §3.4 对应行与
 * {@code RateLimitThresholdsTest} 对账断言，缺一即视为未改。</p>
 */
public final class RateLimitThresholds {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private RateLimitThresholds() {
    }

    // --- 窗口秒数（通用三档 + 登录锁定档）-----------------------------------------

    /** 1 分钟滚动窗口（秒）。详设 §3.4 各 {@code :1m} 轨。 */
    public static final long WINDOW_MINUTE_SECONDS = 60;

    /** 1 小时滚动窗口（秒）。详设 §3.4 各 {@code :1h} 轨。 */
    public static final long WINDOW_HOUR_SECONDS = 3_600;

    /** 1 日窗口（秒）。详设 §3.4 各 {@code :1d} 轨为<b>自然日</b>窗口（KTD6：键尾内嵌
     * 日期片、TTL 给 26h 防跨日残留），本值是秒数换算基准，非自然日语义本身。 */
    public static final long WINDOW_DAY_SECONDS = 86_400;

    /** 限频计数/窗口的时区固化。KTD6：自然日窗口以 Asia/Shanghai 计日，不依赖 JVM
     * 默认时区（容器时区漂移会改变「今日」边界）。 */
    public static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");

    // --- 行 1：短信发送（手机号）1/min、5/h、10/d → 42905 --------------------------

    /** 短信·手机号维度 1 分钟窗阈值。详设 §3.4 第 1 行「1/min」。 */
    public static final int SMS_PHONE_LIMIT_PER_MINUTE = 1;

    /** 短信·手机号维度 1 小时窗阈值。详设 §3.4 第 1 行「5/h」。 */
    public static final int SMS_PHONE_LIMIT_PER_HOUR = 5;

    /** 短信·手机号维度 1 自然日窗阈值。详设 §3.4 第 1 行「10/d」。 */
    public static final int SMS_PHONE_LIMIT_PER_DAY = 10;

    // --- 行 2：短信发送（IP）20/h → 42905 ------------------------------------------

    /** 短信·IP 维度 1 小时窗阈值。详设 §3.4 第 2 行「20/h」。 */
    public static final int SMS_IP_LIMIT_PER_HOUR = 20;

    // --- 行 3：登录失败 5 次 → 锁 15min → 40105 ------------------------------------

    /** 登录失败计数阈值（次）。详设 §3.4 第 3 行「5 次 → 锁 15min」；PRD §12.5
     * 「登录失败 5 次，锁定 15 分钟」。 */
    public static final int LOGIN_FAIL_THRESHOLD = 5;

    /** 登录失败锁定时长（秒）= 15 分钟。详设 §3.4 第 3 行；同时是 40105 响应
     * {@code Retry-After} 的上界来源（锁定剩余秒数）。 */
    public static final long LOGIN_FAIL_LOCK_SECONDS = 900;

    // --- 行 4：联系（账号）30/d → 42902 --------------------------------------------

    /** 联系方式拉取·账号维度 1 自然日阈值。详设 §3.4 第 4 行「30/d」。 */
    public static final int CONTACT_UID_LIMIT_PER_DAY = 30;

    // --- 行 5：联系（设备）30/d → 42902 --------------------------------------------

    /** 联系方式拉取·设备辅助维度 1 自然日阈值。详设 §3.4 第 5 行「30/d」
     * （账号级辅助轨）。 */
    public static final int CONTACT_DEV_LIMIT_PER_DAY = 30;

    // --- 行 6：联系（IP）100/d → 42902 ---------------------------------------------

    /** 联系方式拉取·IP 渠道维度 1 自然日阈值。详设 §3.4 第 6 行「100/d」。 */
    public static final int CONTACT_IP_LIMIT_PER_DAY = 100;

    // --- 行 7：联系熔断 1min ≥10 次 → 当日冻结 → 42903 ------------------------------

    /** 联系熔断·1 分钟窗触发阈值（次）。详设 §3.4 第 7 行「1min ≥10 次 → 当日冻结」；
     * 触发后的当日冻结标记走 {@code fz:contact:{userId}:{date}} 键（键拼装归 U4），
     * 本常量只是计数轨阈值。 */
    public static final int CONTACT_BURST_LIMIT_PER_MINUTE = 10;

    // --- 行 8：举报频次 → 42903 ----------------------------------------------------

    /** 举报·账号维度 1 自然日阈值（次）。详设 §3.4 第 8 行阈值列原文为「熔断同上」——
     * 数值沿第 7 行联系熔断的 10 次，窗口取键形 {@code rl:report:uid:{userId}:1d} 的
     * 自然日；超限语义同为 42903（当日冻结型）。若详设后续评审将本行改为 1min 窗口
     * 语义，改本常量与 {@code RateLimitTrackTest} 对账断言即可。 */
    public static final int REPORT_UID_LIMIT_PER_DAY = 10;

    // --- 行 9：埋点上报 60 请求/min → 42906 ----------------------------------------

    /** 埋点上报·账号维度 1 分钟窗阈值（请求数/min）。详设 §3.4 第 9 行
     * 「60 请求/min」；编码规范 §4.7「埋点：60 请求/min」同口径。 */
    public static final int TRACK_UID_LIMIT_PER_MINUTE = 60;

    // --- 行 10：未登录详情（设备）30/d → 42907 -------------------------------------

    /** 未登录详情浏览·设备维度 1 自然日阈值。详设 §3.4 第 10 行「30/d」；阈值沿用
     * 联系方式设备档（详设明文「不新造数字」）。仅未登录请求生效（判定点在鉴权
     * 上下文之后，R1/U7）。 */
    public static final int GUEST_DETAIL_DEV_LIMIT_PER_DAY = 30;

    // --- 行 11：未登录详情（IP）100/d → 42907 --------------------------------------

    /** 未登录详情浏览·IP 渠道维度 1 自然日阈值。详设 §3.4 第 11 行「100/d」；
     * 阈值沿用联系方式 IP 档（详设明文「不新造数字」）。 */
    public static final int GUEST_DETAIL_IP_LIMIT_PER_DAY = 100;

    // --- 超限码（引用 ErrorCode 唯一口径源，PRD §12.5）-----------------------------

    /** 短信发送超限码（详设 §3.4 第 1–2 行）。{@code 42905}，needRetryAfter。 */
    public static final ErrorCode SMS_OVERFLOW = ErrorCode.SMS_LIMIT;

    /** 登录失败锁定超限码（详设 §3.4 第 3 行）。{@code 40105}，needRetryAfter。 */
    public static final ErrorCode LOGIN_FAIL_OVERFLOW = ErrorCode.LOGIN_LOCKED;

    /** 联系方式拉取超限码（详设 §3.4 第 4–6 行，账号/设备/IP 三维同码，
     * 响应不区分命中维度）。{@code 42902}，needRetryAfter。 */
    public static final ErrorCode CONTACT_OVERFLOW = ErrorCode.CONTACT_LIMIT;

    /** 联系熔断超限码（详设 §3.4 第 7 行）。{@code 42903}，needRetryAfter。 */
    public static final ErrorCode CONTACT_BURST_OVERFLOW = ErrorCode.CIRCUIT_BROKEN;

    /** 举报频次超限码（详设 §3.4 第 8 行）。{@code 42903}，needRetryAfter。 */
    public static final ErrorCode REPORT_OVERFLOW = ErrorCode.CIRCUIT_BROKEN;

    /** 埋点上报超限码（详设 §3.4 第 9 行）。{@code 42906}，needRetryAfter；
     * 唯一不向用户呈现的错误码（客户端静默退回队列）。 */
    public static final ErrorCode TRACK_OVERFLOW = ErrorCode.TRACK_LIMIT;

    /** 未登录详情浏览超限码（详设 §3.4 第 10–11 行，设备/IP 两维同码）。{@code 42907}，
     * needRetryAfter；仅未登录请求生效。 */
    public static final ErrorCode GUEST_DETAIL_OVERFLOW = ErrorCode.GUEST_DETAIL_LIMIT;
}
