package com.s2s.server.common.idempotency;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.IdempotencyPolicy;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.slf4j.MDC;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.method.HandlerMethod;

/**
 * {@link IdempotencyInterceptor} 纯判定测试（[122] U5；详设 §3.3；KTD4/KTD13/KTD7）。
 *
 * <p>覆盖计划 U5 四类必测输入 + 扩展场景（逐条对应 R8）：
 * <ol>
 *   <li>缺失 Idempotency-Key → 40001；</li>
 *   <li>大写 / v1 UUID → 40001；</li>
 *   <li>登录态键无 AuthContext → 40101；</li>
 *   <li>执行者 SETNX 成功 → 返回 true + 键形 idem:{userId}:{key}；</li>
 *   <li>匿名键合法设备头 → idem:dev:{deviceId}:{key}；</li>
 *   <li>匿名键缺设备头 → idem:anon:{key}（KTD13 降级）；</li>
 *   <li>重放：SETNX 失败 + 轮询读到完成 JSON → 返回 false + ATTR_REPLAY_BODY；</li>
 *   <li>首次失败后重放：轮询读到 null → 重新 SETNX 成功转执行者；</li>
 *   <li>轮询超时 → 50001（注入短超时避免真实等待）；</li>
 *   <li>Redis SETNX 异常 → 50001（KTD7 读路径红线）；</li>
 *   <li>无注解 / 非 HandlerMethod → 放行零动作。</li>
 * </ol>
 *
 * <p>测试策略：Redis 用 Mockito mock；短轮询参数（1ms 间隔 / 10ms 超时）注入，
 * 覆盖轮询超时分支而不真实等待 10s。
 */
class IdempotencyInterceptorTest {

    /** 测试用合法 UUID v4（幂等键）。 */
    private static final String VALID_KEY = "550e8400-e29b-41d4-a716-446655440000";

    /** 测试用合法 UUID v4（设备 ID）。 */
    private static final String VALID_DEVICE = "f47ac10b-58cc-4372-a567-0e02b2c3d479";

    /** mock Redis 模板与 ValueOperations。 */
    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOps;

    /** 被测拦截器（短轮询参数注入）。 */
    private IdempotencyInterceptor interceptor;

    /**
     * 每测前置：构造 mock Redis 与短轮询拦截器，清空 MDC。
     *
     * @return void
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        // 短轮询：1ms 间隔、10ms 超时，覆盖超时分支不真实等待
        interceptor = new IdempotencyInterceptor(redisTemplate, 1, 10);
        MDC.clear();
    }

    /**
     * 每测后置：清空 MDC（AuthContext.setUserId 会写 user_id）。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        MDC.clear();
    }

    // ------------------------------------------------------------------
    // 四类必测输入之一：键缺失 / 非法
    // ------------------------------------------------------------------

    /**
     * 场景一：缺失 Idempotency-Key 头 → 40001（不放行）。
     *
     * @return void；断言失败即缺键未拒绝
     */
    @Test
    void missingKeyThrowsParamInvalid() {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        AuthContext.setUserId(request, 42L);
        HandlerMethod handler = handler("loginRequired");

        assertThatThrownBy(() -> interceptor.preHandle(request, new MockHttpServletResponse(), handler))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));
    }

    /**
     * 场景二：大写 UUID / v1 UUID → 40001（详设 §3.3 幂等键正则）。
     *
     * @return void；断言失败即非法键未被拒绝
     */
    @Test
    void malformedKeyThrowsParamInvalid() {
        // 大写
        MockHttpServletRequest upper = new MockHttpServletRequest("POST", "/posts");
        upper.addHeader("Idempotency-Key", "550E8400-E29B-41D4-A716-446655440000");
        AuthContext.setUserId(upper, 42L);
        assertThatThrownBy(() -> interceptor.preHandle(upper, new MockHttpServletResponse(),
                handler("loginRequired")))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));

        // v1（版本位 1）
        MockHttpServletRequest v1 = new MockHttpServletRequest("POST", "/posts");
        v1.addHeader("Idempotency-Key", "550e8400-e29b-11d4-a716-446655440000");
        AuthContext.setUserId(v1, 42L);
        assertThatThrownBy(() -> interceptor.preHandle(v1, new MockHttpServletResponse(),
                handler("loginRequired")))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));
    }

    // ------------------------------------------------------------------
    // 键维度分流（KTD13）
    // ------------------------------------------------------------------

    /**
     * 场景三：登录态键无 AuthContext → 40101（KTD13 分支另一侧）。
     *
     * @return void；断言失败即登录态键未要求登录
     */
    @Test
    void loginRequiredWithoutAuthContextThrowsUnauthorized() {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        // 不设置 AuthContext = 游客

        assertThatThrownBy(() -> interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired")))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景四：执行者 SETNX 成功 → 返回 true，键形 idem:{userId}:{key}，ATTR_REDIS_KEY 写入。
     *
     * @return void；断言失败即执行者判定或键拼装错误
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void executorAcquiresWithUserIdKey() throws Exception {
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(true);

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        AuthContext.setUserId(request, 42L);

        boolean result = interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired"));

        assertThat(result).isTrue();
        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY))
                .isEqualTo("idem:42:" + VALID_KEY);
        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REPLAY_BODY)).isNull();
    }

    /**
     * 场景五：匿名键 + 合法设备头 → 键形 idem:dev:{deviceId}:{key}。
     *
     * @return void；断言失败即匿名设备维度键拼装错误
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void anonymousWithDeviceUsesDeviceKey() throws Exception {
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(true);

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/auth/sms/send");
        request.addHeader("Idempotency-Key", VALID_KEY);
        request.addHeader("X-Device-Id", VALID_DEVICE);

        interceptor.preHandle(request, new MockHttpServletResponse(), handler("anonymousWrite"));

        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY))
                .isEqualTo("idem:dev:" + VALID_DEVICE + ":" + VALID_KEY);
    }

    /**
     * 场景六：匿名键 + 缺设备头 → 降级键形 idem:anon:{key}（KTD13/KTD14）。
     *
     * @return void；断言失败即匿名降级分支未生效
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void anonymousWithoutDeviceFallsBackToAnonKey() throws Exception {
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(true);

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/auth/sms/send");
        request.addHeader("Idempotency-Key", VALID_KEY);
        // 无 X-Device-Id 头

        interceptor.preHandle(request, new MockHttpServletResponse(), handler("anonymousWrite"));

        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY))
                .isEqualTo("idem:anon:" + VALID_KEY);
    }

    // ------------------------------------------------------------------
    // 重放与轮询
    // ------------------------------------------------------------------

    /**
     * 场景七：重放——SETNX 失败 + 轮询读到完成 JSON → 返回 false + ATTR_REPLAY_BODY
     * 写入首次响应原文。
     *
     * @return void；断言失败即重放路径未正确短路
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void replayReturnsCachedBody() throws Exception {
        String cachedJson = "{\"code\":0,\"message\":\"success\",\"data\":null,\"request_id\":\"first-req\"}";
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(false);
        when(valueOps.get(anyString())).thenReturn(cachedJson);

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        AuthContext.setUserId(request, 42L);

        boolean result = interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired"));

        assertThat(result).isFalse();
        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REPLAY_BODY))
                .isEqualTo(cachedJson);
        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY)).isNull();
    }

    /**
     * 场景八：首次失败后重放——轮询读到 null（首次执行者失败已 DEL）→ 重新 SETNX 成功，
     * 本请求转执行者。
     *
     * @return void；断言失败即「失败删键后重放重新执行」未闭环
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void replayAfterFirstFailureReacquires() throws Exception {
        when(valueOps.get(anyString())).thenReturn(null); // 首次失败删键
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS)))
                .thenReturn(false)  // 首次 SETNX（进入轮询）
                .thenReturn(true);  // 重试 SETNX（转执行者）

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        AuthContext.setUserId(request, 42L);

        boolean result = interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired"));

        assertThat(result).isTrue();
        assertThat(request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY))
                .isEqualTo("idem:42:" + VALID_KEY);
    }

    /**
     * 场景九：轮询超时（get 一直 PENDING）→ 50001（注入 10ms 短超时，不真实等待）。
     *
     * @return void；断言失败即轮询超时未返回 50001
     */
    @Test
    void pollTimeoutThrowsInternalError() {
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS))).thenReturn(false);
        when(valueOps.get(anyString())).thenReturn(IdempotencyPolicy.PENDING_PLACEHOLDER);

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        AuthContext.setUserId(request, 42L);

        assertThatThrownBy(() -> interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired")))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.INTERNAL_ERROR));
    }

    // ------------------------------------------------------------------
    // Redis 故障（KTD7 读路径红线）
    // ------------------------------------------------------------------

    /**
     * 场景十：SETNX 抛异常（Redis 故障）→ 50001，不降级放行。
     *
     * @return void；断言失败即 KTD7 红线未守住（幂等写故障放行会导致重复写）
     */
    @Test
    void redisSetFailureThrowsInternalError() {
        when(valueOps.setIfAbsent(anyString(), eq(IdempotencyPolicy.PENDING_PLACEHOLDER),
                anyLong(), eq(TimeUnit.SECONDS)))
                .thenThrow(new RuntimeException("Redis connection refused"));

        MockHttpServletRequest request = new MockHttpServletRequest("POST", "/posts");
        request.addHeader("Idempotency-Key", VALID_KEY);
        AuthContext.setUserId(request, 42L);

        assertThatThrownBy(() -> interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("loginRequired")))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.INTERNAL_ERROR));
    }

    // ------------------------------------------------------------------
    // 豁免路径
    // ------------------------------------------------------------------

    /**
     * 场景十一：无 @Idempotent 注解 → 放行，零 Redis 动作。
     *
     * @return void；断言失败即无注解接口被错误幂等处理
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void methodWithoutAnnotationPasses() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");

        boolean result = interceptor.preHandle(request, new MockHttpServletResponse(),
                handler("noIdempotent"));

        assertThat(result).isTrue();
        verify(valueOps, never()).setIfAbsent(anyString(), anyString(), anyLong(),
                any(TimeUnit.class));
    }

    /**
     * 场景十二：非 HandlerMethod handler → 放行。
     *
     * @return void；断言失败即非 HandlerMethod 被错误处理
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void nonHandlerMethodPasses() throws Exception {
        boolean result = interceptor.preHandle(new MockHttpServletRequest("GET", "/x"),
                new MockHttpServletResponse(), new Object());

        assertThat(result).isTrue();
    }

    /**
     * 测试辅助：从测试 Controller 反射取方法构造 HandlerMethod。
     *
     * @param methodName 方法名
     * @return {@link HandlerMethod} 携带对应方法的 @Idempotent 注解
     */
    private HandlerMethod handler(String methodName) {
        try {
            Method method = TestController.class.getMethod(methodName);
            return new HandlerMethod(new TestController(), method);
        } catch (NoSuchMethodException exception) {
            throw new IllegalArgumentException("测试辅助方法缺失: " + methodName, exception);
        }
    }

    /**
     * 测试辅助 Controller：声明带 @Idempotent 注解的方法。
     */
    private static final class TestController {

        /** 登录态写接口（默认 anonymous=false）。 */
        @Idempotent
        public void loginRequired() {
        }

        /** 匿名写接口（anonymous=true，走 dev/anon 键维度）。 */
        @Idempotent(anonymous = true)
        public void anonymousWrite() {
        }

        /** 无注解方法。 */
        public void noIdempotent() {
        }
    }
}