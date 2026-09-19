package com.s2s.server.crosscut;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.auth.JwtVerifier;
import com.s2s.server.common.idempotency.IdempotencyCaptureFilter;
import com.s2s.server.common.idempotency.IdempotencyInterceptor;
import com.s2s.server.common.ratelimit.RateLimitInterceptor;
import com.s2s.server.common.ratelimit.RateLimiter;
import com.s2s.server.common.web.GlobalExceptionHandler;
import com.s2s.server.common.web.RequestIdFilter;
import com.s2s.server.common.web.ResponseBodyWrapper;
import java.util.Arrays;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/**
 * 横切链集成断言（[122] U7；详设 §3.1；S1 出口「横切链自测过」载体）。
 *
 * <p>以 standalone MockMvc 组装<b>真实横切件</b>（仅 JwtVerifier 与 Redis 用 mock/fake，
 * 避免真实 JWT 签发与 Redis 依赖），断言链序与协作行为而非实现细节：
 * <ol>
 *   <li>限流先于幂等：同时满足「限流超限 + 缺幂等键」→ 先返 429（非 40001），
 *       Retry-After 为整数秒；</li>
 *   <li>全链 request_id：响应体 request_id 非空（RequestIdFilter 生成 → 属性 → 信封三处一致）；</li>
 *   <li>幂等重放：SETNX 失败 + 轮询读到缓存原文 → 原样返回首次响应。</li>
 * </ol>
 *
 * <p>组装口径（对齐 {@code WebCrosscutConfig} 链序）：Filter 层
 * {@code RequestIdFilter → IdempotencyCaptureFilter}；拦截器层
 * {@code AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor}；
 * advice {@code GlobalExceptionHandler + ResponseBodyWrapper}。
 */
class CrosscutChainIntegrationTest {

    /** 测试用合法 UUID v4（幂等键）。 */
    private static final String VALID_KEY = "550e8400-e29b-41d4-a716-446655440000";

    /** mock 的 Redis 模板与 ValueOperations（fake Redis）。 */
    private StringRedisTemplate redis;
    private ValueOperations<String, String> valueOps;

    /** mock 的 JWT 验签器（让 AuthInterceptor 放行，聚焦链序而非重复验签逻辑）。 */
    private JwtVerifier jwtVerifier;

    /**
     * 每测前置：构造 fake Redis 与 mock JwtVerifier。
     * 默认：JwtVerifier 对任意 Token 返回 userId=42（AuthContext 建立）；
     * Redis 各方法由具体测试场景覆盖 stub。
     *
     * @return void
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redis = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(valueOps);
        jwtVerifier = mock(JwtVerifier.class);
        when(jwtVerifier.verifyAndGetUserId(anyString())).thenReturn(42L);
    }

    /**
     * 场景一：限流先于幂等——请求同时满足「限流超限 + 缺 Idempotency-Key」，
     * 应先返 429（CONTACT_LIMIT）而非幂等缺键 40001；Retry-After 为整数秒字符串。
     *
     * @return void；断言失败即链序错位（限流未先于幂等）
     * @throws Exception mockMvc 执行异常（测试固有问题）
     */
    @Test
    void rateLimitPrecedesIdempotency() throws Exception {
        // CONTACT_UID 轨 limit=30，返回 current=31 触发超限，ttl=100
        when(redis.execute(any(RedisScript.class), anyList(), anyString()))
                .thenReturn(Arrays.asList(31L, 100L));

        MockMvc mvc = buildMockMvc();
        mvc.perform(post("/stub/limited-idempotent")
                        .header("Authorization", "Bearer test-token"))
                .andExpect(status().is(429))
                .andExpect(jsonPath("$.code").value(42902))
                .andExpect(header().string("Retry-After", "100"));
    }

    /**
     * 场景二：全链 request_id——普通接口成功，响应体 request_id 非空
     * （RequestIdFilter 生成 → 请求属性 → 信封三处一致）。
     *
     * @return void；断言失败即 request_id 未贯通到响应信封
     * @throws Exception mockMvc 执行异常（测试固有问题）
     */
    @Test
    void requestIdPropagatesToEnvelope() throws Exception {
        MockMvc mvc = buildMockMvc();
        mvc.perform(get("/stub/plain"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value(0))
                .andExpect(jsonPath("$.request_id").isNotEmpty());
    }

    /**
     * 场景三：幂等重放——SETNX 失败 + 轮询读到缓存原文 → 原样返回首次响应
     * （body 逐字节等于缓存 JSON，含首次 request_id）。
     *
     * @return void；断言失败即幂等重放未原样返回首次响应
     * @throws Exception mockMvc 执行异常（测试固有问题）
     */
    @Test
    void idempotencyReplayReturnsFirstResponse() throws Exception {
        String cachedJson = "{\"code\":0,\"message\":\"success\",\"data\":{\"created\":1},\"request_id\":\"first-req\"}";
        when(valueOps.setIfAbsent(anyString(),
                eq(com.s2s.server.common.constants.IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(false);
        when(valueOps.get(anyString())).thenReturn(cachedJson);

        MockMvc mvc = buildMockMvc();
        String body = mvc.perform(post("/stub/idempotent-only")
                        .header("Authorization", "Bearer test-token")
                        .header("Idempotency-Key", VALID_KEY))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        assertThat(body).isEqualTo(cachedJson);
    }

    /**
     * 组装 standalone MockMvc：真实横切件 + fake Redis + mock JwtVerifier，
     * 链序对齐 {@code WebCrosscutConfig}。
     *
     * @return {@link MockMvc} 已组装完整横切链的测试入口
     */
    private MockMvc buildMockMvc() {
        RequestIdFilter requestIdFilter = new RequestIdFilter();
        IdempotencyCaptureFilter captureFilter = new IdempotencyCaptureFilter(redis);
        AuthInterceptor authInterceptor = new AuthInterceptor(jwtVerifier);
        RateLimiter rateLimiter = new RateLimiter(redis);
        RateLimitInterceptor rateLimitInterceptor = new RateLimitInterceptor(rateLimiter);
        IdempotencyInterceptor idempotencyInterceptor = new IdempotencyInterceptor(redis);

        return MockMvcBuilders.standaloneSetup(new StubControllers())
                .addFilters(requestIdFilter, captureFilter)
                .addInterceptors(authInterceptor, rateLimitInterceptor, idempotencyInterceptor)
                .setControllerAdvice(new GlobalExceptionHandler(),
                        new ResponseBodyWrapper(new ObjectMapper()))
                .build();
    }
}