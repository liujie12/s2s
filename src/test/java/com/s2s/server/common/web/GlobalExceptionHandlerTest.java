package com.s2s.server.common.web;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;

/**
 * {@link GlobalExceptionHandler} 异常映射测试。
 *
 * <p>覆盖 U-3 任务两场景（KTD-10 本条目范围）：
 * {@code BizException(42902, retryAfterSeconds=3600)} → HTTP 429、响应体 code=42902、
 * 整数秒 {@code Retry-After: 3600} 响应头（全系统唯一写该头的位置，详设 §2.2 纪律）；
 * 未知 {@link RuntimeException} → 50001 且响应体无堆栈字段（日志打全栈、响应体无堆栈）。
 * 选纯单测路径（U-3 任务书授权「@WebMvcTest 或纯单测均可，选最快路径」）。
 *
 * <p>proof-first：本测试先于生产代码编写（U-3），首轮运行应编译失败。
 */
class GlobalExceptionHandlerTest {

    private final GlobalExceptionHandler handler = new GlobalExceptionHandler();
    private final ObjectMapper objectMapper = new ObjectMapper();

    /**
     * 每测前置：经 {@link RequestContextFixtures} 安装带预置 request_id 的请求上下文，
     * 验证 handler 注入的 request_id 逐字沿用请求属性（与 wrapper 同一最小实现路径，[124] 衔接）。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        RequestContextFixtures.install("req-handler-1");
    }

    /**
     * 每测后置：经 {@link RequestContextFixtures} 清空线程本地请求上下文，避免测试间串扰。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        RequestContextFixtures.clear();
    }

    /**
     * 场景一：携带剩余秒数的限频 {@link BizException}（42902）映射为 HTTP 429，
     * 响应体 code=42902、data 恒 null、request_id 逐字沿用，且写出整数秒 {@code Retry-After} 头。
     * 依据：详设 §2.2 映射表「BizException → 取其 ErrorCode；retryAfterSec != null 则写 Retry-After 头」；
     * PRD §12.5「所有 429 段错误码与 40105 必须同时返回 Retry-After 响应头，值为剩余秒数（整数）」。
     *
     * @return void；断言失败即 BizException 映射或 Retry-After 写入逻辑错误
     */
    @Test
    void bizExceptionWithRetryAfterWritesHeader() {
        BizException exception = BizException.ofRetryAfter(ErrorCode.CONTACT_LIMIT, 3600L);

        ResponseEntity<ApiResponse<Void>> response = handler.handleBizException(exception);

        assertThat(response.getStatusCode().value()).isEqualTo(429);
        assertThat(response.getHeaders().getFirst(HttpHeaders.RETRY_AFTER)).isEqualTo("3600");
        ApiResponse<Void> body = response.getBody();
        assertThat(body).isNotNull();
        assertThat(body.code()).isEqualTo(42902);
        assertThat(body.message()).isEqualTo(ErrorCode.CONTACT_LIMIT.getMessage());
        assertThat(body.data()).isNull();
        assertThat(body.requestId()).isEqualTo("req-handler-1");
    }

    /**
     * 场景二：未知 {@link RuntimeException} 兜底映射为 HTTP 500 + 50001，
     * 响应体序列化后仅含 code/message/data/request_id 四键、无任何堆栈字段
     * （详设 §2.2「日志打全栈，响应体不含堆栈信息」；安全口径：禁止把服务端堆栈透传到 UI，PRD §12.5）。
     *
     * @return void；断言失败即兜底映射错误或堆栈泄漏
     */
    @Test
    void unknownExceptionMapsTo50001WithoutStacktrace() {
        ResponseEntity<ApiResponse<Void>> response = handler.handleUnexpected(new RuntimeException("boom"));

        assertThat(response.getStatusCode().value()).isEqualTo(500);
        ApiResponse<Void> body = response.getBody();
        assertThat(body).isNotNull();
        assertThat(body.code()).isEqualTo(50001);
        assertThat(body.message()).isEqualTo(ErrorCode.INTERNAL_ERROR.getMessage());
        assertThat(body.data()).isNull();

        JsonNode json = objectMapper.valueToTree(body);
        assertThat(json.fieldNames()).toIterable()
                .containsExactlyInAnyOrder("code", "message", "data", "request_id");
    }
}
