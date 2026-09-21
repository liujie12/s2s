package com.s2s.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.Test;

/**
 * {@link RateLimitTrack} 枚举绑定守门测试（[122] U1；架构验证 D7）。
 *
 * <p>职责：断言 11 轨逐轨与 {@link RateLimitThresholds} 常量的<b>绑定关系</b>——
 * 本测试不写死数字（「常量 vs 详设 §3.4」的值对账归 {@code RateLimitThresholdsTest}），
 * 只锁「轨定义 → 常量引用」一层：多窗口轨 SMS_PHONE 的三个规则必须逐一绑定
 * 对应窗口的常量（防第 2 窗误绑第 3 窗阈值这类「绑错常量」缺陷），超限码断言
 * 同一实例（枚举单例，{@code isSameAs} 即编译期绑定验证）。</p>
 *
 * <p>两层守门链：详设 §3.4 原文 →（ThresholdsTest 对账）→ RateLimitThresholds
 * 常量 →（本测试对账）→ 轨定义 →（U4 消费）。任一层漂移都会在对应测试红。</p>
 */
class RateLimitTrackTest {

    /**
     * 断言轨总数恰为 11（详设 §3.4 键表 11 行的逐行映射，一行一轨）。
     *
     * @return void；断言失败即轨被增删，键表映射不再一一对应
     */
    @Test
    void trackCountIsExactly11() {
        assertThat(RateLimitTrack.values()).hasSize(11);
    }

    /**
     * 断言多窗口轨 SMS_PHONE 绑定 3 个窗口规则，且逐规则的阈值/窗口秒/超限码
     * 与 {@link RateLimitThresholds} 对应常量相等（1m/1h/1d 三窗各自绑各自的阈值，
     * 防窗口错位绑定）。
     * 依据：详设 §3.4 行 1 键形 {@code rl:sms:phone:{phone}:{1m|1h|1d}}——
     * 一个键前缀三个窗口同时生效。
     *
     * @return void；断言失败即三窗绑定错位（如 1h 窗误绑 10/d 阈值）
     */
    @Test
    void smsPhoneBindsThreeWindowRulesEachToItsOwnConstant() {
        RateLimitTrack.WindowRule[] rules = RateLimitTrack.SMS_PHONE.rules();

        assertThat(rules).hasSize(3);
        assertThat(rules[0].limit()).isEqualTo(RateLimitThresholds.SMS_PHONE_LIMIT_PER_MINUTE);
        assertThat(rules[0].windowSeconds()).isEqualTo(RateLimitThresholds.WINDOW_MINUTE_SECONDS);
        assertThat(rules[0].overflowCode()).isSameAs(RateLimitThresholds.SMS_OVERFLOW);
        assertThat(rules[1].limit()).isEqualTo(RateLimitThresholds.SMS_PHONE_LIMIT_PER_HOUR);
        assertThat(rules[1].windowSeconds()).isEqualTo(RateLimitThresholds.WINDOW_HOUR_SECONDS);
        assertThat(rules[1].overflowCode()).isSameAs(RateLimitThresholds.SMS_OVERFLOW);
        assertThat(rules[2].limit()).isEqualTo(RateLimitThresholds.SMS_PHONE_LIMIT_PER_DAY);
        assertThat(rules[2].windowSeconds()).isEqualTo(RateLimitThresholds.WINDOW_DAY_SECONDS);
        assertThat(rules[2].overflowCode()).isSameAs(RateLimitThresholds.SMS_OVERFLOW);
    }

    /**
     * 断言其余 10 个单窗口轨各绑定恰 1 个规则，且三元组逐轨与
     * {@link RateLimitThresholds} 对应常量相等（绑定对账，含登录失败轨窗口秒
     * 绑定锁定时长常量而非通用窗口档）。
     * 依据：详设 §3.4 行 2–11 每行单窗口；窗口秒来源逐轨见常量注释。
     *
     * @return void；断言失败即某单窗轨绑错常量（阈值/窗口/超限码任一）
     */
    @Test
    void singleWindowTracksBindTheirOwnConstants() {
        assertSingleRule(RateLimitTrack.SMS_IP,
                RateLimitThresholds.SMS_IP_LIMIT_PER_HOUR,
                RateLimitThresholds.WINDOW_HOUR_SECONDS,
                RateLimitThresholds.SMS_OVERFLOW);
        assertSingleRule(RateLimitTrack.LOGIN_FAIL,
                RateLimitThresholds.LOGIN_FAIL_THRESHOLD - 1,
                RateLimitThresholds.LOGIN_FAIL_LOCK_SECONDS,
                RateLimitThresholds.LOGIN_FAIL_OVERFLOW);
        assertSingleRule(RateLimitTrack.CONTACT_UID,
                RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.CONTACT_OVERFLOW);
        assertSingleRule(RateLimitTrack.CONTACT_DEV,
                RateLimitThresholds.CONTACT_DEV_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.CONTACT_OVERFLOW);
        assertSingleRule(RateLimitTrack.CONTACT_IP,
                RateLimitThresholds.CONTACT_IP_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.CONTACT_OVERFLOW);
        assertSingleRule(RateLimitTrack.CONTACT_BURST,
                RateLimitThresholds.CONTACT_BURST_LIMIT_PER_MINUTE,
                RateLimitThresholds.WINDOW_MINUTE_SECONDS,
                RateLimitThresholds.CONTACT_BURST_OVERFLOW);
        assertSingleRule(RateLimitTrack.REPORT_UID,
                RateLimitThresholds.REPORT_UID_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.REPORT_OVERFLOW);
        assertSingleRule(RateLimitTrack.TRACK_UID,
                RateLimitThresholds.TRACK_UID_LIMIT_PER_MINUTE,
                RateLimitThresholds.WINDOW_MINUTE_SECONDS,
                RateLimitThresholds.TRACK_OVERFLOW);
        assertSingleRule(RateLimitTrack.GUEST_DETAIL_DEV,
                RateLimitThresholds.GUEST_DETAIL_DEV_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.GUEST_DETAIL_OVERFLOW);
        assertSingleRule(RateLimitTrack.GUEST_DETAIL_IP,
                RateLimitThresholds.GUEST_DETAIL_IP_LIMIT_PER_DAY,
                RateLimitThresholds.WINDOW_DAY_SECONDS,
                RateLimitThresholds.GUEST_DETAIL_OVERFLOW);
    }

    /**
     * 断言全部轨全部规则的超限码均为 needRetryAfter（429 段/40105 语义）。
     * 依据：编码规范 §3.2——限频超限码抛出必须携带剩余秒数，U4 消费方将经
     * {@code BizException.ofRetryAfter} 抛出（Retry-After 头唯一写入处在
     * GlobalExceptionHandler）。
     *
     * @return void；断言失败即某轨绑定非 Retry-After 码，超限响应缺头
     */
    @Test
    void everyTrackOverflowCodeRequiresRetryAfter() {
        for (RateLimitTrack track : RateLimitTrack.values()) {
            for (RateLimitTrack.WindowRule rule : track.rules()) {
                assertThat(rule.overflowCode().isNeedRetryAfter())
                        .as("轨 %s 的超限码 %s 必须是 needRetryAfter 码",
                                track.name(), rule.overflowCode())
                        .isTrue();
            }
        }
    }

    /**
     * 断言 {@code rules()} 返回防御性拷贝：调用方改副本不影响轨定义。
     * 依据：{@link RateLimitTrack#rules()} 的契约（数组副本）——枚举定义是
     * 全局共享的不可变注册表，外部可变泄漏会破坏「轨定义即详设 §3.4」的唯一性。
     *
     * @return void；断言失败即 rules() 泄漏内部数组引用
     */
    @Test
    void rulesReturnsDefensiveCopy() {
        RateLimitTrack.WindowRule[] mutated = RateLimitTrack.CONTACT_UID.rules();
        mutated[0] = null;

        assertThat(RateLimitTrack.CONTACT_UID.rules()).hasSize(1);
        assertThat(RateLimitTrack.CONTACT_UID.rules()[0].limit())
                .isEqualTo(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY);
    }

    /**
     * 单窗口轨绑定断言辅助：轨规则数恰 1 且三元组逐项与常量相等（超限码同一实例）。
     *
     * @param track        被断言的键轨
     * @param expectLimit  期望绑定的阈值常量
     * @param expectWindow 期望绑定的窗口秒常量
     * @param expectCode   期望绑定的超限码常量
     */
    private static void assertSingleRule(RateLimitTrack track, int expectLimit,
            long expectWindow, ErrorCode expectCode) {
        RateLimitTrack.WindowRule[] rules = track.rules();
        assertThat(rules).as("轨 %s 应恰有 1 个窗口规则", track.name()).hasSize(1);
        assertThat(rules[0].limit()).as("轨 %s 阈值绑定", track.name()).isEqualTo(expectLimit);
        assertThat(rules[0].windowSeconds()).as("轨 %s 窗口秒绑定", track.name())
                .isEqualTo(expectWindow);
        assertThat(rules[0].overflowCode()).as("轨 %s 超限码绑定", track.name())
                .isSameAs(expectCode);
    }
}
