package com.s2s.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import java.lang.reflect.Method;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.slf4j.MDC;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.method.HandlerMethod;

/**
 * {@link RateLimitInterceptor} 声明式限频测试（[122] U4；详设 §3.1 横切链第三位、§3.4）。
 *
 * <p>覆盖测试场景（对照计划 U4 Test scenarios）：
 * <ol>
 *   <li>无注解方法 → 放行，不调 RateLimiter；</li>
 *   <li>非 HandlerMethod handler → 放行；</li>
 *   <li>多轨声明（contact uid/dev/ip）+ 已登录 → 按登录态拼三轨；</li>
 *   <li>设备头缺失 → dev 轨跳过，uid/ip 轨照常；</li>
 *   <li>42907：guest detail 轨 + 游客 → 双轨计数；</li>
 *   <li>42907：guest detail 轨 + 已登录 → 跳过（不计数，鉴权后判定）；</li>
 *   <li>设备头格式非法 → dev 轨跳过、ip 轨照常（KTD14）；</li>
 *   <li>超限 → RateLimiter 抛异常，拦截器上抛（不直写头）。</li>
 * </ol>
 *
 * <p>测试策略：RateLimiter 用 Mockito mock（计数逻辑在 RateLimiterTest 单测覆盖），
 * 本测试聚焦<b>拦截器的注解解析 + 键拼装 + 维度判定</b>；请求用 Spring Mock，
 * AuthContext 真实工作（登录态经 setUserId 设置）；HandlerMethod 经反射
 * 从测试辅助 Controller 构造。
 */
class RateLimitInterceptorTest {

    /** mock 的限频计数器（拦截器依赖）。 */
    private RateLimiter rateLimiter;

    /** 被测拦截器。 */
    private RateLimitInterceptor interceptor;

    /**
     * 每测前置：构造 mock limiter 与拦截器，清空 MDC。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        rateLimiter = mock(RateLimiter.class);
        interceptor = new RateLimitInterceptor(rateLimiter);
        MDC.clear();
    }

    /**
     * 每测后置：清空 MDC（AuthContext.setUserId 会写 MDC user_id）。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        MDC.clear();
    }

    /**
     * 场景一：无 @RateLimit 注解的方法 → 放行，不调 RateLimiter。
     *
     * @return void；断言失败即无注解方法被错误限频
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void methodWithoutAnnotationPassesWithoutLimiting() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        HandlerMethod handler = handler("noLimit");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        verify(rateLimiter, never()).incrementAndCheck(anyList());
    }

    /**
     * 场景二：handler 非 HandlerMethod（如静态资源）→ 放行。
     *
     * @return void；断言失败即非 HandlerMethod 被错误处理
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void nonHandlerMethodPasses() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/static/logo.png");

        interceptor.preHandle(request, new MockHttpServletResponse(), new Object());

        verify(rateLimiter, never()).incrementAndCheck(anyList());
    }

    /**
     * 场景三：联系方式多轨（uid/dev/ip）+ 已登录 + 合法设备头 → 三轨全拼。
     * 断言 entries 的 key 前缀分别为 uid 42 / dev 设备ID / ip。
     *
     * @return void；断言失败即键拼装或维度判定错误
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void contactLoggedInWithDeviceBuildsThreeTracks() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/1/contact");
        request.addHeader("X-Device-Id", "550e8400-e29b-41d4-a716-446655440000");
        AuthContext.setUserId(request, 42L);
        HandlerMethod handler = handler("contact");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        ArgumentCaptor<List<RateLimiter.RateLimitEntry>> captor = ArgumentCaptor.forClass(List.class);
        verify(rateLimiter).incrementAndCheck(captor.capture());
        List<RateLimiter.RateLimitEntry> entries = captor.getValue();
        assertThat(entries).hasSize(3);
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:contact:uid:42:1d:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:contact:dev:550e8400-e29b-41d4-a716-446655440000:1d:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:contact:ip:"));
    }

    /**
     * 场景四：联系方式多轨 + 已登录 + 设备头缺失 → dev 轨跳过，uid/ip 两轨照常。
     *
     * @return void；断言失败即缺设备头未正确降级
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void contactLoggedInWithoutDeviceSkipsDevTrack() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/1/contact");
        AuthContext.setUserId(request, 42L);
        HandlerMethod handler = handler("contact");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        ArgumentCaptor<List<RateLimiter.RateLimitEntry>> captor = ArgumentCaptor.forClass(List.class);
        verify(rateLimiter).incrementAndCheck(captor.capture());
        List<RateLimiter.RateLimitEntry> entries = captor.getValue();
        assertThat(entries).hasSize(2);
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:contact:uid:42:1d:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:contact:ip:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .noneMatch(k -> k.startsWith("rl:contact:dev:"));
    }

    /**
     * 场景五：guest detail 双轨 + 游客 + 合法设备头 → 双轨计数（42907）。
     *
     * @return void；断言失败即游客详情限频未正确启用
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void guestDetailAsGuestBuildsBothTracks() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/42");
        request.addHeader("X-Device-Id", "550e8400-e29b-41d4-a716-446655440000");
        HandlerMethod handler = handler("guestDetail");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        ArgumentCaptor<List<RateLimiter.RateLimitEntry>> captor = ArgumentCaptor.forClass(List.class);
        verify(rateLimiter).incrementAndCheck(captor.capture());
        List<RateLimiter.RateLimitEntry> entries = captor.getValue();
        assertThat(entries).hasSize(2);
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::overflowCode)
                .allMatch(code -> code == ErrorCode.GUEST_DETAIL_LIMIT);
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:guestdetail:dev:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:guestdetail:ip:"));
    }

    /**
     * 场景六：guest detail 双轨 + 已登录 → 跳过（42907 仅未登录生效，鉴权后判定）。
     * 已登录用户不消耗游客额度，不调 RateLimiter（entries 为空）。
     *
     * @return void；断言失败即登录态未跳过游客详情限频
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void guestDetailLoggedInSkipsBothTracks() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/42");
        request.addHeader("X-Device-Id", "550e8400-e29b-41d4-a716-446655440000");
        AuthContext.setUserId(request, 42L);
        HandlerMethod handler = handler("guestDetail");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        // entries 为空 → 不调 RateLimiter（直接放行）
        verify(rateLimiter, never()).incrementAndCheck(anyList());
    }

    /**
     * 场景七：guest detail + 游客 + 设备头格式非法 → dev 轨跳过、ip 轨照常（KTD14）。
     *
     * @return void；断言失败即设备头非法未正确跳过设备轨
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void guestDetailInvalidDeviceIdSkipsDevKeepsIp() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/42");
        request.addHeader("X-Device-Id", "NOT-A-VALID-DEVICE-ID");
        HandlerMethod handler = handler("guestDetail");

        interceptor.preHandle(request, new MockHttpServletResponse(), handler);

        ArgumentCaptor<List<RateLimiter.RateLimitEntry>> captor = ArgumentCaptor.forClass(List.class);
        verify(rateLimiter).incrementAndCheck(captor.capture());
        List<RateLimiter.RateLimitEntry> entries = captor.getValue();
        assertThat(entries).hasSize(1);
        assertThat(entries.get(0).key()).startsWith("rl:guestdetail:ip:");
    }

    /**
     * 场景八：超限 → RateLimiter 抛 BizException（带 Retry-After），拦截器上抛（不直写响应头）。
     *
     * @return void；断言失败即异常被拦截器吞掉或写头逻辑越权
     */
    @Test
    void overLimitPropagatesException() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/42");
        request.addHeader("X-Device-Id", "550e8400-e29b-41d4-a716-446655440000");
        when(rateLimiter.incrementAndCheck(anyList()))
                .thenThrow(BizException.ofRetryAfter(ErrorCode.GUEST_DETAIL_LIMIT, 120));
        HandlerMethod handler = handler("guestDetail");

        assertThatThrownBy(() -> interceptor.preHandle(request, new MockHttpServletResponse(), handler))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.GUEST_DETAIL_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(120L);
                });
    }

    /**
     * 测试辅助：从测试 Controller 反射取指定方法构造 HandlerMethod。
     *
     * @param methodName 方法名（对应 TestController 中的声明）
     * @return {@link HandlerMethod} 携带对应方法的元信息（含 @RateLimit 注解）
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
     * 测试辅助 Controller：声明带 @RateLimit 注解的方法，供拦截器测试反射取注解。
     * 类与方法均无实际业务逻辑，仅作注解载体。
     */
    private static final class TestController {

        /** 联系方式拉取：账号/设备/IP 三轨。 */
        @RateLimit({RateLimitTrack.CONTACT_UID, RateLimitTrack.CONTACT_DEV, RateLimitTrack.CONTACT_IP})
        public void contact() {
        }

        /** 未登录详情浏览：设备/IP 双轨（42907，仅未登录生效）。 */
        @RateLimit({RateLimitTrack.GUEST_DETAIL_DEV, RateLimitTrack.GUEST_DETAIL_IP})
        public void guestDetail() {
        }

        /** 无注解方法：不触发限频。 */
        public void noLimit() {
        }
    }
}