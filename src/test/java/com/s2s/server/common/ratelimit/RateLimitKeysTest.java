package com.s2s.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.LocalDate;
import org.junit.jupiter.api.Test;

/**
 * {@link RateLimitKeys} 键拼装测试（[122] U4；详设 §3.4 键表 11 行；KTD6/KTD14）。
 *
 * <p>覆盖测试场景：
 * <ol>
 *   <li>11 行键形逐条对账（键前缀 + 维度 + 窗口后缀日期片）；</li>
 *   <li>类型分维：账号维方法签名收 Long userId、渠道维收 String phone/ip、
 *       设备维收 String deviceId（编译期即分维，测试仅验证值正确）；</li>
 *   <li>自然日键尾日期片：yyyyMMdd 格式，与时区 ZONE 一致；</li>
 *   <li>设备 ID 格式校验（KTD14）：合法 UUID v4 通过、大写/无横杠/v1/空/null 均不通过。</li>
 * </ol>
 */
class RateLimitKeysTest {

    /** 测试用日期（固定，避免测试结果随日期变化）。 */
    private static final LocalDate TEST_DATE = LocalDate.of(2026, 9, 18);

    // ------------------------------------------------------------------
    // 行 1：短信·手机号
    // ------------------------------------------------------------------

    @Test
    void smsPhoneMinuteKeyShape() {
        assertThat(RateLimitKeys.smsPhoneMinute("13800138000"))
                .isEqualTo("rl:sms:phone:13800138000:1m");
    }

    @Test
    void smsPhoneHourKeyShape() {
        assertThat(RateLimitKeys.smsPhoneHour("13800138000"))
                .isEqualTo("rl:sms:phone:13800138000:1h");
    }

    @Test
    void smsPhoneDayKeyShapeWithDateSlice() {
        assertThat(RateLimitKeys.smsPhoneDay("13800138000", TEST_DATE))
                .isEqualTo("rl:sms:phone:13800138000:1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 2：短信·IP
    // ------------------------------------------------------------------

    @Test
    void smsIpHourKeyShape() {
        assertThat(RateLimitKeys.smsIpHour("192.168.1.1"))
                .isEqualTo("rl:sms:ip:192.168.1.1:1h");
    }

    // ------------------------------------------------------------------
    // 行 3：登录失败
    // ------------------------------------------------------------------

    @Test
    void loginFailKeyShape() {
        assertThat(RateLimitKeys.loginFail("13800138000"))
                .isEqualTo("rl:login:fail:13800138000");
    }

    // ------------------------------------------------------------------
    // 行 4：联系·账号（Long 类型分维）
    // ------------------------------------------------------------------

    @Test
    void contactUidDayKeyShapeWithDateSlice() {
        assertThat(RateLimitKeys.contactUidDay(42L, TEST_DATE))
                .isEqualTo("rl:contact:uid:42:1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 5：联系·设备
    // ------------------------------------------------------------------

    @Test
    void contactDevDayKeyShape() {
        String devId = "550e8400-e29b-41d4-a716-446655440000";
        assertThat(RateLimitKeys.contactDevDay(devId, TEST_DATE))
                .isEqualTo("rl:contact:dev:" + devId + ":1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 6：联系·IP
    // ------------------------------------------------------------------

    @Test
    void contactIpDayKeyShape() {
        assertThat(RateLimitKeys.contactIpDay("10.0.0.1", TEST_DATE))
                .isEqualTo("rl:contact:ip:10.0.0.1:1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 7：联系熔断·账号
    // ------------------------------------------------------------------

    @Test
    void contactBurstMinuteKeyShape() {
        assertThat(RateLimitKeys.contactBurstMinute(77L))
                .isEqualTo("rl:contact:burst:77:1m");
    }

    // ------------------------------------------------------------------
    // 行 8：举报·账号
    // ------------------------------------------------------------------

    @Test
    void reportUidDayKeyShape() {
        assertThat(RateLimitKeys.reportUidDay(88L, TEST_DATE))
                .isEqualTo("rl:report:uid:88:1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 9：埋点·账号
    // ------------------------------------------------------------------

    @Test
    void trackUidMinuteKeyShape() {
        assertThat(RateLimitKeys.trackUidMinute(99L))
                .isEqualTo("rl:track:uid:99:1m");
    }

    // ------------------------------------------------------------------
    // 行 10：未登录详情·设备
    // ------------------------------------------------------------------

    @Test
    void guestDetailDevDayKeyShape() {
        String devId = "550e8400-e29b-41d4-a716-446655440000";
        assertThat(RateLimitKeys.guestDetailDevDay(devId, TEST_DATE))
                .isEqualTo("rl:guestdetail:dev:" + devId + ":1d:20260918");
    }

    // ------------------------------------------------------------------
    // 行 11：未登录详情·IP
    // ------------------------------------------------------------------

    @Test
    void guestDetailIpDayKeyShape() {
        assertThat(RateLimitKeys.guestDetailIpDay("172.16.0.1", TEST_DATE))
                .isEqualTo("rl:guestdetail:ip:172.16.0.1:1d:20260918");
    }

    // ------------------------------------------------------------------
    // 设备 ID 格式校验（KTD14）
    // ------------------------------------------------------------------

    @Test
    void validDeviceIdV4LowercaseAccepted() {
        // 标准 UUID v4 小写 + 横杠
        assertThat(RateLimitKeys.isValidDeviceId("550e8400-e29b-41d4-a716-446655440000")).isTrue();
        assertThat(RateLimitKeys.isValidDeviceId("f47ac10b-58cc-4372-a567-0e02b2c3d479")).isTrue();
    }

    @Test
    void invalidDeviceIdRejected() {
        // 大写 → 不通过（前端生成的是小写，大写视为伪造）
        assertThat(RateLimitKeys.isValidDeviceId("550E8400-E29B-41D4-A716-446655440000")).isFalse();
        // v1（时间戳版本）→ 不通过
        assertThat(RateLimitKeys.isValidDeviceId("550e8400-e29b-11d4-a716-446655440000")).isFalse();
        // 无横杠 → 不通过
        assertThat(RateLimitKeys.isValidDeviceId("550e8400e29b41d4a716446655440000")).isFalse();
        // 空串 → 不通过
        assertThat(RateLimitKeys.isValidDeviceId("")).isFalse();
        // null → 不通过
        assertThat(RateLimitKeys.isValidDeviceId(null)).isFalse();
        // 随意字符串 → 不通过
        assertThat(RateLimitKeys.isValidDeviceId("my-device-id")).isFalse();
        // 路径遍历字符 → 不通过
        assertThat(RateLimitKeys.isValidDeviceId("../../etc/passwd")).isFalse();
    }

    // ------------------------------------------------------------------
    // today() 方法存在且返回非 null（不验证具体值，避免测试随日期失败）
    // ------------------------------------------------------------------

    @Test
    void todayReturnsNonNullDate() {
        assertThat(RateLimitKeys.today()).isNotNull();
    }
}
