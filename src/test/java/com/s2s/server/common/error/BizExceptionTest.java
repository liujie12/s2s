package com.s2s.server.common.error;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Arrays;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * {@link BizException} 工厂构造期守卫测试（[122] P2 #4；编码规范 §3.2）。
 *
 * <p>覆盖测试场景（对照计划 U6 Test scenarios）：
 * <ol>
 *   <li>{@code of(needRetryAfter 8 码任一)} → {@link IllegalArgumentException}（参数化）；</li>
 *   <li>{@code ofRetryAfter(非 needRetryAfter 码)} → {@link IllegalArgumentException}；</li>
 *   <li>{@code of(普通码)} → 正常创建，无剩余秒数；</li>
 *   <li>{@code ofRetryAfter(Retry-After 码)} → 正常创建，携带剩余秒数。</li>
 * </ol>
 *
 * <p>语义：needRetryAfter 码「必须带秒数」与非 Retry-After 码「禁带秒数」都应在构造期
 * 「不可表示」，而非运行期 Handler 记 WARN 兜底——把缺陷暴露在最早点（范式对齐
 * {@code SecretsProperties} 守卫）。
 */
class BizExceptionTest {

    /**
     * needRetryAfter 的 8 个码（供参数化测试）。从 {@link ErrorCode} 枚举过滤，
     * 与 {@link ErrorCodeTest#needRetryAfterCodesAreExactlyThe8Named()} 口径一致。
     *
     * @return {@link Stream} 8 个 needRetryAfter 码
     */
    static Stream<ErrorCode> needRetryAfterCodes() {
        return Arrays.stream(ErrorCode.values()).filter(ErrorCode::isNeedRetryAfter);
    }

    /**
     * 场景一：{@code of()} 传入 needRetryAfter 8 码任一 → 抛 {@link IllegalArgumentException}
     * （不带秒数不可表示，必须用 {@code ofRetryAfter}）。
     *
     * @param errorCode needRetryAfter 码（参数化注入）
     * @return void；断言失败即守卫未拦住带秒数码走无秒工厂
     */
    @ParameterizedTest
    @MethodSource("needRetryAfterCodes")
    void ofRejectsNeedRetryAfterCodes(ErrorCode errorCode) {
        assertThatThrownBy(() -> BizException.of(errorCode))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining(String.valueOf(errorCode.getCode()));
    }

    /**
     * 场景二：{@code ofRetryAfter()} 传入非 needRetryAfter 码 → 抛
     * {@link IllegalArgumentException}（非 Retry-After 码不可携带秒数）。
     *
     * @return void；断言失败即守卫未拦住非 Retry-After 码走带秒工厂
     */
    @Test
    void ofRetryAfterRejectsNonRetryAfterCodes() {
        assertThatThrownBy(() -> BizException.ofRetryAfter(ErrorCode.INTERNAL_ERROR, 30))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining(String.valueOf(ErrorCode.INTERNAL_ERROR.getCode()));
    }

    /**
     * 场景三：{@code of()} 传入普通码（非 needRetryAfter）→ 正常创建，无剩余秒数。
     *
     * @return void；断言失败即正向路径被误伤
     */
    @Test
    void ofAcceptsNormalCodes() {
        BizException exception = BizException.of(ErrorCode.PARAM_INVALID);

        assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.PARAM_INVALID);
        assertThat(exception.getRetryAfterSeconds()).isNull();
    }

    /**
     * 场景四：{@code ofRetryAfter()} 传入 needRetryAfter 码 → 正常创建，携带剩余秒数。
     *
     * @return void；断言失败即正向路径被误伤
     */
    @Test
    void ofRetryAfterAcceptsRetryAfterCodes() {
        BizException exception = BizException.ofRetryAfter(ErrorCode.CONTACT_LIMIT, 42);

        assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
        assertThat(exception.getRetryAfterSeconds()).isEqualTo(42L);
    }

    /**
     * 未给覆盖文案时，异常 message 逐字取错误码全局文案（KTD4 的默认行为不变）。
     *
     * @return void；断言失败即普通异常文案被意外改写
     */
    @Test
    void messageDefaultsToErrorCodeCopy() {
        BizException exception = BizException.of(ErrorCode.NO_PERMISSION);

        assertThat(exception.getMessage()).isEqualTo(ErrorCode.NO_PERMISSION.getMessage());
        assertThat(exception.getMessageOverride()).isNull();
    }

    /**
     * 给覆盖文案时，异常 message 为专用文案（KTD4：三处接口专用提示）。
     *
     * @return void；断言失败即接口专用文案不生效，用户看到错位提示
     */
    @Test
    void messageOverrideReplacesErrorCodeCopy() {
        BizException exception = BizException.of(ErrorCode.NO_PERMISSION, "消息功能维护中，请稍后再试");

        assertThat(exception.getMessage()).isEqualTo("消息功能维护中，请稍后再试");
        assertThat(exception.getMessageOverride()).isEqualTo("消息功能维护中，请稍后再试");
    }

    /**
     * 带秒工厂同样支持覆盖文案，且构造期守卫仍先于文案生效。
     *
     * @return void；断言失败即额度提示丢失秒数或守卫被绕过
     */
    @Test
    void ofRetryAfterSupportsMessageOverrideWithSameGuards() {
        BizException exception = BizException.ofRetryAfter(ErrorCode.CONTACT_LIMIT, 60, "今日发起会话数已达上限");

        assertThat(exception.getRetryAfterSeconds()).isEqualTo(60L);
        assertThat(exception.getMessage()).isEqualTo("今日发起会话数已达上限");
        assertThatThrownBy(() ->
                BizException.ofRetryAfter(ErrorCode.NO_PERMISSION, 60, "x"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}