package com.s2s.server.common.idempotency;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import jakarta.servlet.FilterChain;
import jakarta.servlet.http.HttpServletResponse;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/**
 * {@link IdempotencyCaptureFilter} 响应捕获与出口结算测试（[122] U5；架构评审 P0）。
 *
 * <p>覆盖测试场景（对照计划 U5 Test scenarios）：
 * <ol>
 *   <li>执行者 + 2xx → SET 覆盖占位键为响应体 JSON（TTL 24h，断言参数）；</li>
 *   <li>执行者 + 非 2xx → DEL 占位键（同 Key 重放重新执行）；</li>
 *   <li>重放者 → 原样写出首次响应 body，Content-Type=JSON、Content-Length 正确；</li>
 *   <li>无幂等属性 → 仅 copyBodyToResponse，响应 body 正确输出（漏调即空响应——绊线）；</li>
 *   <li>Redis SET/DEL 失败 → 不抛异常（依赖 TTL 自愈）。</li>
 * </ol>
 */
class IdempotencyCaptureFilterTest {

    /** mock Redis 模板与 ValueOperations。 */
    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOps;

    /** 被测捕获 Filter。 */
    private IdempotencyCaptureFilter filter;

    /**
     * 每测前置：构造 mock Redis 与被测 Filter。
     *
     * @return void
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        filter = new IdempotencyCaptureFilter(redisTemplate);
    }

    /**
     * 场景一：执行者 + 2xx → SET 覆盖占位键（TTL 24h = 86400s），响应 body 正确落客户端。
     *
     * @return void；断言失败即成功缓存未覆盖占位或 copyBodyToResponse 漏调
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void executorSuccessSettlesAndCopiesBody() throws Exception {
        String bodyJson = "{\"code\":0,\"message\":\"success\",\"data\":null,\"request_id\":\"r1\"}";
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.setAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY, "idem:42:key");
        MockHttpServletResponse response = new MockHttpServletResponse();

        FilterChain chain = (req, res) -> {
            HttpServletResponse httpRes = (HttpServletResponse) res;
            httpRes.setStatus(200);
            httpRes.setContentType(MediaType.APPLICATION_JSON_VALUE);
            httpRes.getWriter().write(bodyJson);
        };

        filter.doFilter(request, response, chain);

        // SET 覆盖：key=idem:42:key, value=bodyJson, ttl=86400s
        verify(valueOps).set(eq("idem:42:key"), eq(bodyJson), eq(86400L), eq(TimeUnit.SECONDS));
        // copyBodyToResponse 落客户端：body 非空（绊线）
        assertThat(response.getContentAsString()).isEqualTo(bodyJson);
    }

    /**
     * 场景二：执行者 + 非 2xx → DEL 占位键（同 Key 重放重新执行）。
     *
     * @return void；断言失败即失败响应未删占位
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void executorFailureDeletesPlaceholder() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.setAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY, "idem:42:key");
        MockHttpServletResponse response = new MockHttpServletResponse();

        FilterChain chain = (req, res) -> {
            HttpServletResponse httpRes = (HttpServletResponse) res;
            httpRes.setStatus(500);
            httpRes.getWriter().write("{\"code\":50001,\"message\":\"err\"}");
        };

        filter.doFilter(request, response, chain);

        verify(redisTemplate).delete("idem:42:key");
        verify(valueOps, never()).set(anyString(), anyString(), eq(86400L), eq(TimeUnit.SECONDS));
    }

    /**
     * 场景三：重放者 → 原样写出首次响应 body，Content-Type=JSON、Content-Length 正确。
     *
     * @return void；断言失败即重放未原样写出或 Content-Length 错误
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void replayWritesCachedBodyWithContentLength() throws Exception {
        String cachedJson = "{\"code\":0,\"message\":\"success\",\"data\":null,\"request_id\":\"first-req\"}";
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.setAttribute(IdempotencyInterceptor.ATTR_REPLAY_BODY, cachedJson);
        MockHttpServletResponse response = new MockHttpServletResponse();

        FilterChain chain = (req, res) -> {
            // controller 未执行（拦截器返回 false），chain 不写任何内容
        };

        filter.doFilter(request, response, chain);

        assertThat(response.getContentAsString()).isEqualTo(cachedJson);
        assertThat(response.getContentType()).isEqualTo(MediaType.APPLICATION_JSON_VALUE);
        assertThat(response.getContentLength())
                .isEqualTo(cachedJson.getBytes(StandardCharsets.UTF_8).length);
        // 重放不碰 Redis（SET/DEL 都不应发生）
        verify(valueOps, never()).set(anyString(), anyString(), eq(86400L), eq(TimeUnit.SECONDS));
        verify(redisTemplate, never()).delete(anyString());
    }

    /**
     * 场景四：无幂等属性 → 仅 copyBodyToResponse，响应 body 正确输出（绊线：漏调即空响应）。
     *
     * @return void；断言失败即无幂等请求被错误处理或 body 丢失
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void nonIdempotentRequestOnlyCopiesBody() throws Exception {
        String bodyJson = "{\"code\":0,\"message\":\"success\",\"data\":\"x\",\"request_id\":\"r2\"}";
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        // 无 ATTR_REDIS_KEY / ATTR_REPLAY_BODY
        MockHttpServletResponse response = new MockHttpServletResponse();

        FilterChain chain = (req, res) -> {
            HttpServletResponse httpRes = (HttpServletResponse) res;
            httpRes.setStatus(200);
            httpRes.setContentType(MediaType.APPLICATION_JSON_VALUE);
            httpRes.getWriter().write(bodyJson);
        };

        filter.doFilter(request, response, chain);

        assertThat(response.getContentAsString()).isEqualTo(bodyJson);
        verify(valueOps, never()).set(anyString(), anyString(), eq(86400L), eq(TimeUnit.SECONDS));
        verify(redisTemplate, never()).delete(anyString());
    }

    /**
     * 场景五：Redis SET 失败 → 不抛异常（响应已产生，依赖 TTL 自愈）。
     *
     * @return void；断言失败即 Redis 写失败被错误上抛覆盖已成功响应
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void redisSetFailureDoesNotPropagate() throws Exception {
        String bodyJson = "{\"code\":0,\"message\":\"success\",\"data\":null,\"request_id\":\"r3\"}";
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.setAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY, "idem:42:key");
        MockHttpServletResponse response = new MockHttpServletResponse();
        doThrow(new RuntimeException("Redis down"))
                .when(valueOps).set(anyString(), anyString(), eq(86400L), eq(TimeUnit.SECONDS));

        FilterChain chain = (req, res) -> {
            HttpServletResponse httpRes = (HttpServletResponse) res;
            httpRes.setStatus(200);
            httpRes.getWriter().write(bodyJson);
        };

        // 不抛异常，响应仍正确输出
        filter.doFilter(request, response, chain);
        assertThat(response.getContentAsString()).isEqualTo(bodyJson);
    }

    /**
     * 场景六：Redis DEL 失败 → 不抛异常（依赖 TTL 自愈）。
     *
     * @return void；断言失败即 DEL 失败被错误上抛
     * @throws Exception filter 执行异常（测试固有问题）
     */
    @Test
    void redisDeleteFailureDoesNotPropagate() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.setAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY, "idem:42:key");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(redisTemplate.delete(anyString())).thenThrow(new RuntimeException("Redis down"));

        FilterChain chain = (req, res) -> {
            HttpServletResponse httpRes = (HttpServletResponse) res;
            httpRes.setStatus(500);
            httpRes.getWriter().write("{\"code\":50001,\"message\":\"err\"}");
        };

        filter.doFilter(request, response, chain);
        assertThat(response.getStatus()).isEqualTo(500);
    }
}