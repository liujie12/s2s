package com.s2s.server.common.web;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.FieldError;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * 全系统<b>唯一异常→错误码映射处</b>，亦是<b>唯一写 {@code Retry-After} 响应头的位置</b>
 * （详设 §2.2；编码规范 §1.2 唯一实现处清单）。业务代码只在 {@link BizException}
 * 里携带剩余秒数，不各自写 header（详设 §2.2 纪律）。
 *
 * <p>本条目（U-3，KTD-10）落地两条映射：{@link BizException} → 取其 {@link ErrorCode}；
 * 兜底 {@link Exception} → {@code 50001}（日志打全栈、响应体无堆栈）。
 * {@link MethodArgumentNotValidException} → {@code 40001}（message 拼字段名）随 [123] U4
 * （首个带 {@code @Valid} 的业务接口 {@code POST /auth/sms/send}）补充；
 * {@link HttpMessageNotReadableException} → {@code 40001} 随 2026-10-15 线上实测补充
 * （原缺此映射，坏 JSON 被兜成 {@code 50001}，把输入错误伪装成服务端故障）。以下为剩余扩展点，
 * 随业务条目补充，禁止提前实现（KTD-10）：
 * <ul>
 *   <li>{@code MissingRequestHeaderException} / {@code ConstraintViolationException} →
 *       {@code 40001}，message 拼出具体字段名；</li>
 *   <li>{@code OptimisticLockException}（自定义，mapper 更新 0 行时抛）→ {@code 40903}。</li>
 * </ul>
 *
 * <p>响应体统一 {@link ApiResponse}（handler 返回值经 {@code ResponseBodyWrapper.supports()}
 * 判定不再二次套壳）；{@code request_id} 经 {@link ResponseBodyWrapper#resolveOrCreateRequestId()}
 * 注入（[122] {@code RequestIdFilter} 衔接点同 wrapper）。
 *
 * <p>{@code basePackages = "com.s2s.server"} 限定作用域（[122] P2 #8）：与
 * {@code ResponseBodyWrapper} 同口径——不限定则 {@code /error} 错误派发路径的
 * {@code BasicErrorController} 会被本 advice 匹配，套上 {@code code=0} 假成功信封。
 */
@RestControllerAdvice(basePackages = "com.s2s.server")
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    /**
     * 映射业务异常：取 {@link ErrorCode} 的 code/message/httpStatus 构造响应；
     * 异常携带剩余秒数时写入整数秒 {@code Retry-After} 响应头（全系统唯一写入点）。
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
        // 无剩余秒数时不构造 HttpHeaders：空头对象与无头响应线上输出完全一致。
        // needRetryAfter=true 的码已在 BizException.of() 构造期被拒收（[122] P2 #4），
        // 故此处不可能出现「true 码缺秒数」——不再保留运行期 WARN 绊线。
        if (retryAfterSeconds == null) {
            return ResponseEntity.status(errorCode.getHttpStatus()).body(errorBody(errorCode));
        }
        HttpHeaders headers = new HttpHeaders();
        headers.set(HttpHeaders.RETRY_AFTER, String.valueOf(retryAfterSeconds));
        return ResponseEntity.status(errorCode.getHttpStatus())
                .headers(headers)
                .body(errorBody(errorCode));
    }

    /**
     * 映射 Bean Validation 失败：取首个字段校验错误，拼出字段名返回 {@code 40001}
     * （message 拼字段名口径，详设 §2.2；对齐 openapi BadRequest 示例「缺少必填参数 grid_id」）。
     *
     * @param exception 参数校验异常，携带绑定结果（取其首个字段错误定位字段名）
     * @return {@link ResponseEntity}：HTTP 400，响应体
     *         {@code ApiResponse(40001, "缺少必填参数 " + field, null, requestId)}
     */
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiResponse<Void>> handleValidation(MethodArgumentNotValidException exception) {
        String field = exception.getBindingResult().getFieldErrors().stream()
                .findFirst()
                .map(FieldError::getField)
                .orElse("");
        return ResponseEntity.status(ErrorCode.PARAM_INVALID.getHttpStatus())
                .body(new ApiResponse<>(ErrorCode.PARAM_INVALID.getCode(),
                        "缺少必填参数 " + field, null,
                        ResponseBodyWrapper.resolveOrCreateRequestId()));
    }

    /**
     * 映射请求体解析失败：返回 {@code 40001}，不让「客户端输入错误」伪装成服务端故障。
     *
     * <p>背景（2026-10-15 线上实测）：本类原先无此映射，坏 JSON（语法错误、缺引号等）会落到
     * {@link #handleUnexpected(Exception)} 兜成 {@code 50001 服务繁忙}，读起来像后端挂了。
     * 该伪装在一次排查中直接把定位带偏——真相是探针工具发出了缺引号的报文，与后端无关。</p>
     *
     * <p>message 取 {@link ErrorCode#PARAM_INVALID} 的通用文案，<b>不</b>沿用
     * {@link #handleValidation(MethodArgumentNotValidException)} 的「缺少必填参数 X」：
     * 体解析失败时字段名未知，拼不出来。</p>
     *
     * <p><b>刻意不打印异常堆栈、只取类名</b>：Jackson 解析异常的 message 内嵌原始报文片段
     * （形如 {@code (String)"{phone:18674750845,...}"}），落日志即泄漏完整手机号
     * （编码规范 §4.11 PII 红线）。故只记一行不含报文的 WARN，排障经访问日志的 path/code。</p>
     *
     * @param exception 请求体解析异常（其消息内嵌原始报文，故只取类名、不打印对象）
     * @return {@link ResponseEntity}：HTTP 400，响应体
     *         {@code ApiResponse(40001, ErrorCode.PARAM_INVALID.message, null, requestId)}
     */
    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ApiResponse<Void>> handleUnreadableBody(
            HttpMessageNotReadableException exception) {
        log.warn("请求体解析失败，映射 40001（{}；异常消息含原始报文故不落堆栈）",
                exception.getClass().getSimpleName());
        return ResponseEntity.status(ErrorCode.PARAM_INVALID.getHttpStatus())
                .body(errorBody(ErrorCode.PARAM_INVALID));
    }

    /**
     * 请求体 Content-Type 不被支持时映射 {@code 40001}（而不是兜底 {@code 50001}）。
     *
     * <p><b>为什么单独处理（2026-10-29 线上实测）</b>：客户端把 JSON 以
     * {@code application/octet-stream} 发出时，Spring 抛
     * {@link HttpMediaTypeNotSupportedException}，原先落到兜底分支回 {@code 50001}，
     * 前端按「可自动重试」重试 2 次后仍失败，最终呈现为「网络异常」——把客户端的
     * 错误归成了服务端故障。该异常本质是请求参数非法，按 {@code 40001} 返回更准确，
     * 也避免无意义重试。</p>
     *
     * @param exception Content-Type 不支持异常
     * @return {@link ResponseEntity}：HTTP 400，响应体
     *         {@code ApiResponse(40001, ErrorCode.PARAM_INVALID.message, null, requestId)}
     */
    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    public ResponseEntity<ApiResponse<Void>> handleUnsupportedMediaType(
            HttpMediaTypeNotSupportedException exception) {
        log.warn("请求 Content-Type 不支持，映射 40001（{}）",
                exception.getClass().getSimpleName());
        return ResponseEntity.status(ErrorCode.PARAM_INVALID.getHttpStatus())
                .body(errorBody(ErrorCode.PARAM_INVALID));
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
