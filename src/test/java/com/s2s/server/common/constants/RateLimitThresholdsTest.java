package com.s2s.server.common.constants;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.ZoneId;
import org.junit.jupiter.api.Test;

/**
 * {@link RateLimitThresholds} 对账守门测试（[122] U1；详设 §7.2「会失败的自动化」）。
 *
 * <p>职责：把「服务端单端正源」的 11 行键表（详设 §3.4）从人眼评审转为逐值对账断言——
 * 期望值<b>刻意写死详设原文数字</b>（对账的意义即硬编码期望，与 {@code ErrorCodeTest}
 * 写死 PRD §12.5 数字同范式），任一常量抄录漂移（看错行、看错列、多敲一个 0）
 * 都会让本测试红。与本测试互补的 {@code RateLimitTrackTest} 只对账
 * 「枚举绑定 → 常量引用」一层，两层守门缺一不可：本测试锁「常量 vs 详设」，
 * 彼测试锁「轨定义 vs 常量」。</p>
 *
 * <p>出处：详设 §3.4 键表 11 行（阈值/窗口/超限码三元组）、KTD6（自然日窗口时区）、
 * KTD11（服务端单端正源的例外登记）。</p>
 */
class RateLimitThresholdsTest {

    /**
     * 对账行 1：短信发送·手机号维度三窗阈值「1/min、5/h、10/d」→ 42905。
     * 依据：详设 §3.4 第 1 行原文；渠道级保留手机号维度（未登录无 user_id，纪律 2）。
     *
     * @return void；断言失败即三窗任一阈值抄录漂移
     */
    @Test
    void smsPhoneThresholdsMatchDesignRow1() {
        assertThat(RateLimitThresholds.SMS_PHONE_LIMIT_PER_MINUTE)
                .as("详设 §3.4 行 1「1/min」").isEqualTo(1);
        assertThat(RateLimitThresholds.SMS_PHONE_LIMIT_PER_HOUR)
                .as("详设 §3.4 行 1「5/h」").isEqualTo(5);
        assertThat(RateLimitThresholds.SMS_PHONE_LIMIT_PER_DAY)
                .as("详设 §3.4 行 1「10/d」").isEqualTo(10);
        assertThat(RateLimitThresholds.SMS_OVERFLOW.getCode())
                .as("详设 §3.4 行 1 超限码 42905").isEqualTo(42905);
    }

    /**
     * 对账行 2：短信发送·IP 维度「20/h」→ 42905。
     * 依据：详设 §3.4 第 2 行原文。
     *
     * @return void；断言失败即 IP 维阈值抄录漂移
     */
    @Test
    void smsIpThresholdMatchesDesignRow2() {
        assertThat(RateLimitThresholds.SMS_IP_LIMIT_PER_HOUR)
                .as("详设 §3.4 行 2「20/h」").isEqualTo(20);
        assertThat(RateLimitThresholds.SMS_OVERFLOW.getCode())
                .as("详设 §3.4 行 2 超限码 42905").isEqualTo(42905);
    }

    /**
     * 对账行 3：登录失败「5 次 → 锁 15min」→ 40105。
     * 依据：详设 §3.4 第 3 行原文；900 秒 = 15 分钟（锁定时长）。
     *
     * @return void；断言失败即失败计数或锁定时长抄录漂移
     */
    @Test
    void loginFailThresholdAndLockMatchDesignRow3() {
        assertThat(RateLimitThresholds.LOGIN_FAIL_THRESHOLD)
                .as("详设 §3.4 行 3「5 次」").isEqualTo(5);
        assertThat(RateLimitThresholds.LOGIN_FAIL_LOCK_SECONDS)
                .as("详设 §3.4 行 3「锁 15min」= 900 秒").isEqualTo(900);
        assertThat(RateLimitThresholds.LOGIN_FAIL_OVERFLOW.getCode())
                .as("详设 §3.4 行 3 超限码 40105").isEqualTo(40105);
    }

    /**
     * 对账行 4–6：联系方式三维「30/d（账号）、30/d（设备）、100/d（IP）」→ 42902。
     * 依据：详设 §3.4 第 4–6 行原文；三维同码（响应不区分命中维度，编码规范 §4.7）。
     *
     * @return void；断言失败即任一维度阈值抄录漂移（设备 30 与 IP 100 是两档不同数字）
     */
    @Test
    void contactThreeDimensionThresholdsMatchDesignRows4To6() {
        assertThat(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY)
                .as("详设 §3.4 行 4「30/d」（账号维）").isEqualTo(30);
        assertThat(RateLimitThresholds.CONTACT_DEV_LIMIT_PER_DAY)
                .as("详设 §3.4 行 5「30/d」（设备辅助维）").isEqualTo(30);
        assertThat(RateLimitThresholds.CONTACT_IP_LIMIT_PER_DAY)
                .as("详设 §3.4 行 6「100/d」（IP 渠道维）").isEqualTo(100);
        assertThat(RateLimitThresholds.CONTACT_OVERFLOW.getCode())
                .as("详设 §3.4 行 4–6 超限码 42902").isEqualTo(42902);
    }

    /**
     * 对账行 7–8：联系熔断「1min ≥10 次 → 当日冻结」与举报频次「熔断同上」→ 42903。
     * 依据：详设 §3.4 第 7 行原文；第 8 行阈值列原文「熔断同上」——数值沿第 7 行的
     * 10 次、窗口取键形 {@code rl:report:uid:{userId}:1d} 的自然日（解读依据见
     * {@code RateLimitThresholds#REPORT_UID_LIMIT_PER_DAY} 注释，若详设后续评审
     * 改口径须同步改常量与本断言）。
     *
     * @return void；断言失败即熔断/举报阈值抄录漂移
     */
    @Test
    void burstAndReportThresholdsMatchDesignRows7To8() {
        assertThat(RateLimitThresholds.CONTACT_BURST_LIMIT_PER_MINUTE)
                .as("详设 §3.4 行 7「1min ≥10 次」").isEqualTo(10);
        assertThat(RateLimitThresholds.REPORT_UID_LIMIT_PER_DAY)
                .as("详设 §3.4 行 8「熔断同上」（数值 10，窗口 :1d）").isEqualTo(10);
        assertThat(RateLimitThresholds.CONTACT_BURST_OVERFLOW.getCode())
                .as("详设 §3.4 行 7 超限码 42903").isEqualTo(42903);
        assertThat(RateLimitThresholds.REPORT_OVERFLOW.getCode())
                .as("详设 §3.4 行 8 超限码 42903").isEqualTo(42903);
    }

    /**
     * 对账行 9：埋点上报「60 请求/min」→ 42906。
     * 依据：详设 §3.4 第 9 行原文；编码规范 §4.7「埋点：60 请求/min」同口径；
     * 42906 是唯一不向用户呈现的错误码。
     *
     * @return void；断言失败即埋点阈值抄录漂移
     */
    @Test
    void trackThresholdMatchesDesignRow9() {
        assertThat(RateLimitThresholds.TRACK_UID_LIMIT_PER_MINUTE)
                .as("详设 §3.4 行 9「60 请求/min」").isEqualTo(60);
        assertThat(RateLimitThresholds.TRACK_OVERFLOW.getCode())
                .as("详设 §3.4 行 9 超限码 42906").isEqualTo(42906);
    }

    /**
     * 对账行 10–11：未登录详情「设备 30/d、IP 100/d」→ 42907。
     * 依据：详设 §3.4 第 10–11 行原文；阈值沿用联系方式设备/IP 档（详设明文
     * 「不新造数字」），仅未登录请求生效（判定点在鉴权上下文之后）。
     *
     * @return void；断言失败即未登录详情阈值抄录漂移或偏离「不新造数字」口径
     */
    @Test
    void guestDetailThresholdsMatchDesignRows10To11() {
        assertThat(RateLimitThresholds.GUEST_DETAIL_DEV_LIMIT_PER_DAY)
                .as("详设 §3.4 行 10「30/d」（设备维）").isEqualTo(30);
        assertThat(RateLimitThresholds.GUEST_DETAIL_IP_LIMIT_PER_DAY)
                .as("详设 §3.4 行 11「100/d」（IP 维）").isEqualTo(100);
        assertThat(RateLimitThresholds.GUEST_DETAIL_OVERFLOW.getCode())
                .as("详设 §3.4 行 10–11 超限码 42907").isEqualTo(42907);
    }

    /**
     * 对账通用窗口秒与自然日时区：60/3600/86400 与 Asia/Shanghai。
     * 依据：详设 §3.4 键形 {@code :1m/:1h/:1d} 的秒数换算；KTD6 自然日窗口以
     * Asia/Shanghai 计日（不依赖 JVM 默认时区）。
     *
     * @return void；断言失败即窗口秒换算或时区口径漂移
     */
    @Test
    void windowSecondsAndZoneMatchDesignNotation() {
        assertThat(RateLimitThresholds.WINDOW_MINUTE_SECONDS)
                .as("键形 :1m 对应 60 秒").isEqualTo(60);
        assertThat(RateLimitThresholds.WINDOW_HOUR_SECONDS)
                .as("键形 :1h 对应 3600 秒").isEqualTo(3600);
        assertThat(RateLimitThresholds.WINDOW_DAY_SECONDS)
                .as("键形 :1d 对应 86400 秒（自然日语义由 U4 键尾日期片承载）")
                .isEqualTo(86_400);
        assertThat(RateLimitThresholds.ZONE)
                .as("KTD6 自然日窗口时区固化 Asia/Shanghai")
                .isEqualTo(ZoneId.of("Asia/Shanghai"));
    }

    /**
     * 断言 7 个超限码常量全部是 needRetryAfter 码（抛出必须带剩余秒数）。
     * 依据：编码规范 §3.2「429 段与 40105 必带整数秒 Retry-After」——限频超限
     * 全部落在该集合内，若混入非 needRetryAfter 码，GlobalExceptionHandler 将
     * 写不出 Retry-After 头，限频语义直接破缺。
     *
     * @return void；断言失败即某超限码绑定了不带 Retry-After 语义的错误码
     */
    @Test
    void allOverflowCodesRequireRetryAfterSeconds() {
        assertThat(RateLimitThresholds.SMS_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.LOGIN_FAIL_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.CONTACT_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.CONTACT_BURST_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.REPORT_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.TRACK_OVERFLOW.isNeedRetryAfter()).isTrue();
        assertThat(RateLimitThresholds.GUEST_DETAIL_OVERFLOW.isNeedRetryAfter()).isTrue();
    }
}
