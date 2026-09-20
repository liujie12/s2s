package com.s2s.server.common.error;

/**
 * 业务异常：携带 {@link ErrorCode} 与可选剩余秒数，由 {@code GlobalExceptionHandler}
 * 统一映射为 {@code ApiResponse}（详设 §2.2 映射表首行）。
 *
 * <p>纪律：业务代码只负责在异常里带上剩余秒数，<b>不各自写 {@code Retry-After} header</b>
 * ——该头的写入只发生在 {@code GlobalExceptionHandler} 一处（详设 §2.2 纪律；
 * 编码规范 §1.2 唯一实现处清单）。{@code needRetryAfter=true} 的码抛异常必须带剩余秒数，
 * 缺即实现缺陷（编码规范 §3.2）。
 */
public class BizException extends RuntimeException {

    private final ErrorCode errorCode;
    private final Long retryAfterSeconds;

    /**
     * 私有构造：强制经工厂方法创建，保证「带秒数」是显式选择而非随手可填。
     *
     * @param errorCode         业务错误码，异常 message 逐字取其 message（父类 {@link RuntimeException#getMessage()}）
     * @param retryAfterSeconds 剩余秒数（可空）；非空时由 handler 写入整数秒 {@code Retry-After} 响应头
     */
    private BizException(ErrorCode errorCode, Long retryAfterSeconds) {
        super(errorCode.getMessage());
        this.errorCode = errorCode;
        this.retryAfterSeconds = retryAfterSeconds;
    }

    /**
     * 工厂：创建不带剩余秒数的业务异常（适用于 {@code needRetryAfter=false} 的码）。
     *
     * <p><b>构造期守卫（[122] P2 #4）</b>：{@code needRetryAfter=true} 的 8 个码
     * （{@code 40105}、{@code 42901}–{@code 42907}）抛异常必须携带剩余秒数，
     * 经本工厂创建会「让错误不可表示」——传入此类码直接抛
     * {@link IllegalArgumentException}，把缺陷暴露在构造期而非运行期（范式对齐
     * {@code SecretsProperties} 守卫）。</p>
     *
     * @param errorCode 业务错误码（须为 {@code needRetryAfter=false}）
     * @return 携带该码的 {@link BizException} 实例
     * @throws IllegalArgumentException errorCode 为 needRetryAfter 码时抛出（实现缺陷）
     */
    public static BizException of(ErrorCode errorCode) {
        if (errorCode.isNeedRetryAfter()) {
            throw new IllegalArgumentException(
                    "needRetryAfter 码须经 ofRetryAfter 创建（编码规范 §3.2），收到: " + errorCode.getCode());
        }
        return new BizException(errorCode, null);
    }

    /**
     * 工厂：创建携带剩余秒数的业务异常（适用于 {@code needRetryAfter=true} 的 8 个码：
     * {@code 40105}、{@code 42901}–{@code 42907}，PRD §12.5 要求响应必带 {@code Retry-After}）。
     *
     * <p><b>构造期守卫（[122] P2 #4，与 {@link #of(ErrorCode)} 对称）</b>：
     * 非 needRetryAfter 码禁用本工厂——传入此类码抛 {@link IllegalArgumentException}，
     * 防「不该带 Retry-After 的码被塞进秒数」。</p>
     *
     * @param errorCode         业务错误码（须为 {@code needRetryAfter=true}）
     * @param retryAfterSeconds 剩余秒数，handler 原样写入整数秒 {@code Retry-After} 响应头
     * @return 携带该码与剩余秒数的 {@link BizException} 实例
     * @throws IllegalArgumentException errorCode 非 needRetryAfter 码时抛出（实现缺陷）
     */
    public static BizException ofRetryAfter(ErrorCode errorCode, long retryAfterSeconds) {
        if (!errorCode.isNeedRetryAfter()) {
            throw new IllegalArgumentException(
                    "非 needRetryAfter 码禁用 ofRetryAfter（编码规范 §3.2），收到: " + errorCode.getCode());
        }
        return new BizException(errorCode, retryAfterSeconds);
    }

    /**
     * 取业务错误码。
     *
     * @return {@link ErrorCode}，handler 取其 code/message/httpStatus 构造响应
     */
    public ErrorCode getErrorCode() {
        return errorCode;
    }

    /**
     * 取剩余秒数。
     *
     * @return {@link Long} 剩余秒数；{@code null} 表示本异常不写 {@code Retry-After} 头
     */
    public Long getRetryAfterSeconds() {
        return retryAfterSeconds;
    }
}
