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
     * @return 无返回值（构造器）
     */
    private BizException(ErrorCode errorCode, Long retryAfterSeconds) {
        super(errorCode.getMessage());
        this.errorCode = errorCode;
        this.retryAfterSeconds = retryAfterSeconds;
    }

    /**
     * 工厂：创建不带剩余秒数的业务异常（适用于 {@code needRetryAfter=false} 的码）。
     *
     * @param errorCode 业务错误码
     * @return 携带该码的 {@link BizException} 实例
     */
    public static BizException of(ErrorCode errorCode) {
        return new BizException(errorCode, null);
    }

    /**
     * 工厂：创建携带剩余秒数的业务异常（适用于 {@code needRetryAfter=true} 的 8 个码：
     * {@code 40105}、{@code 42901}–{@code 42907}，PRD §12.5 要求响应必带 {@code Retry-After}）。
     *
     * @param errorCode         业务错误码
     * @param retryAfterSeconds 剩余秒数，handler 原样写入整数秒 {@code Retry-After} 响应头
     * @return 携带该码与剩余秒数的 {@link BizException} 实例
     */
    public static BizException ofRetryAfter(ErrorCode errorCode, long retryAfterSeconds) {
        return new BizException(errorCode, retryAfterSeconds);
    }

    /**
     * 取业务错误码。
     *
     * @param 无入参
     * @return {@link ErrorCode}，handler 取其 code/message/httpStatus 构造响应
     */
    public ErrorCode getErrorCode() {
        return errorCode;
    }

    /**
     * 取剩余秒数。
     *
     * @param 无入参
     * @return {@link Long} 剩余秒数；{@code null} 表示本异常不写 {@code Retry-After} 头
     */
    public Long getRetryAfterSeconds() {
        return retryAfterSeconds;
    }
}
