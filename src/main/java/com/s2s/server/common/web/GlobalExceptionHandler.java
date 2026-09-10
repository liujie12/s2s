package com.s2s.server.common.web;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * 全系统<b>唯一异常→错误码映射处</b>，亦是<b>唯一写 {@code Retry-After} 响应头的位置</b>
 * （详设 §2.2；编码规范 §1.2 唯一实现处清单）。业务代码只在 {@link BizException}
 * 里携带剩余秒数，不各自写 header（详设 §2.2 纪律）。
 *
 * <p>本条目（U-3，KTD-10）只落地两条映射：{@link BizException} → 取其 {@link ErrorCode}；
 * 兜底 {@link Exception} → {@code 50001}（日志打全栈、响应体无堆栈）。以下为既定扩展点，
 * 随业务条目补充，禁止提前实现（KTD-10）：
 * <ul>
 *   <li>{@code MethodArgumentNotValidException} / {@code MissingRequestHeaderException} /
 *       {@code ConstraintViolationException} → {@code 40001}，message 拼出具体字段名；</li>
 *   <li>{@code OptimisticLockException}（自定义，mapper 更新 0 行时抛）→ {@code 40903}。</li>
 * </ul>
 *
 * <p>响应体统一 {@link ApiResponse}（handler 返回值经 {@code ResponseBodyWrapper.supports()}
 * 判定不再二次套壳）；{@code request_id} 经 {@link ResponseBodyWrapper#resolveOrCreateRequestId()}
 * 注入（[124] {@code RequestIdFilter} 衔接点同 wrapper）。
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    /**
     * 映射业务异常：取 {@link ErrorCode} 的 code/message/httpStatus 构造响应；
     * 异常携带剩余秒数时写入整数秒 {@code Retry-After} 响应头（全系统唯一写入点）。
     * {@code needRetryAfter=true} 的码未携带秒数属实现缺陷（编码规范 §3.2），记 WARN 不静默。
     *
     * @param exception 业务异常，携带 {@link ErrorCode} 与可选剩余秒数
     * @return {@link ResponseEntity}：HTTP 状态取 {@code errorCode.httpStatus}，
     *         响应体 {@code ApiResponse(code, message, data=null, requestId)}，
     *         携带秒数时含 {@code Retry-After} 整数秒头
     */
    @ExceptionHandler(BizException.class)
    public ResponseEntity<ApiResponse<Void>> handleBizException(BizException exception) {
        ErrorCode errorCode = exception.getErrorCode();
        Long retryAfterSeconds = exception.getRetryAfterSeconds();
        // 无剩余秒数时不构造 HttpHeaders：空头对象与无头响应线上输出完全一致
        if (retryAfterSeconds == null) {
            if (errorCode.isNeedRetryAfter()) {
                log.warn("ErrorCode {} needRetryAfter=true 但 BizException 未携带 retryAfterSeconds，属实现缺陷（编码规范 §3.2）",
                        errorCode.getCode());
            }
            return ResponseEntity.status(errorCode.getHttpStatus()).body(errorBody(errorCode));
        }
        HttpHeaders headers = new HttpHeaders();
        headers.set(HttpHeaders.RETRY_AFTER, String.valueOf(retryAfterSeconds));
        return ResponseEntity.status(errorCode.getHttpStatus())
                .headers(headers)
                .body(errorBody(errorCode));
    }

    /**
     * 兜底映射未知异常：一律 {@code 50001}。日志打全栈（排查依据），
     * 响应体不含任何堆栈信息（详设 §2.2；PRD §12.5：禁止把服务端堆栈透传到 UI）。
     *
     * @param exception 未捕获的任意异常
     * @return {@link ResponseEntity}：HTTP 500，响应体 {@code ApiResponse(50001, message, null, requestId)}
     */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiResponse<Void>> handleUnexpected(Exception exception) {
        log.error("未捕获异常，兜底映射 50001", exception);
        return ResponseEntity.status(ErrorCode.INTERNAL_ERROR.getHttpStatus())
                .body(errorBody(ErrorCode.INTERNAL_ERROR));
    }

    /**
     * 构造错误响应体 {@code ApiResponse(code, message, data=null, requestId)}。
     * 提取原因：该构造表达式在本类两个 handler 中出现第 2 次，按编码规范 §1.1
     * 「同一逻辑出现第 2 次前必须提取为共享实现」收敛为唯一实现处。
     *
     * @param errorCode 业务错误码，取其 code 与 message 填入响应体
     * @return {@link ApiResponse}：data 恒 null（失败响应口径，详设 §2.1），
     *         requestId 经 {@link ResponseBodyWrapper#resolveOrCreateRequestId()} 解析注入
     */
    private static ApiResponse<Void> errorBody(ErrorCode errorCode) {
        return new ApiResponse<>(errorCode.getCode(), errorCode.getMessage(), null,
                ResponseBodyWrapper.resolveOrCreateRequestId());
    }
}
