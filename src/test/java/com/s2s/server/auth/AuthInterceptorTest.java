package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.common.web.RequestIdFilter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/**
 * {@link AuthInterceptor} 行为测试（[122] U3；详设 §3.1 鉴权段；KTD3/KTD7）。
 *
 * <p>覆盖计划 U3 Test scenarios 的拦截器层场景：
 * <ol>
 *   <li>有效 Token 未入黑名单 → 放行（true），AuthContext 含 userId，MDC user_id 写入；</li>
 *   <li>无 Authorization 头 → 放行（true），上下文为空（游客），MDC 无 user_id；</li>
 *   <li>无效签名 / 格式错 / 过期 Token → 40101（三类各一断言，委托 JwtVerifier 实现）；</li>
 *   <li>Token 在黑名单 → 40101；</li>
 *   <li>Redis 查询抛异常 → 50001（KTD7 红线）；</li>
 *   <li>带无效 Token 的匿名接口 → 40101（KTD3：不降级游客，全路径生效）。</li>
 * </ol>
 *
 * <p>测试策略：纯单测（KTD12：不起 Spring 容器），JwtVerifier 用 Mockito mock，
 * 请求/响应用 Spring Mock 实现；MDC 状态用 {@link MDC#getCopyOfContextMap()} 断言。
 */
class AuthInterceptorTest {

    /** mock 的 JWT 验签器（拦截器的依赖）。 */
    private JwtVerifier jwtVerifier;

    /** 被测拦截器。 */
    private AuthInterceptor interceptor;

    /**
     * 每测前置：构造 mock verifier 与被测拦截器，清空 MDC。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        jwtVerifier = mock(JwtVerifier.class);
        interceptor = new AuthInterceptor(jwtVerifier);
        MDC.clear();
    }

    /**
     * 场景一：带有效 Bearer Token → 放行（true），AuthContext 与 MDC 均写入 userId。
     *
     * @return void；断言失败即上下文或 MDC 写入缺失
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void validTokenSetsAuthContextAndMdc() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Bearer valid-token-xyz");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(jwtVerifier.verifyAndGetUserId("valid-token-xyz")).thenReturn(123L);

        boolean result = interceptor.preHandle(request, response, null);

        assertThat(result).isTrue();
        assertThat(AuthContext.currentUserId(request)).isEqualTo(123L);
        assertThat(MDC.get(RequestIdFilter.MDC_USER_ID)).isEqualTo("123");
        verify(jwtVerifier).verifyAndGetUserId("valid-token-xyz");
    }

    /**
     * 场景二：无 Authorization 头 → 放行（true），上下文为空（游客态），MDC 无 user_id。
     * JwtVerifier 不应被调用（缺头直接放行，不尝试验证）。
     *
     * @return void；断言失败即缺头路径错误调用了验签器
     * @throws Exception mock 调用异常（测试固有问题）
     */
    @Test
    void missingHeaderPassesAsGuest() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        MockHttpServletResponse response = new MockHttpServletResponse();

        boolean result = interceptor.preHandle(request, response, null);

        assertThat(result).isTrue();
        assertThat(AuthContext.currentUserId(request)).isNull();
        assertThat(MDC.get(RequestIdFilter.MDC_USER_ID)).isNull();
        verify(jwtVerifier, never()).verifyAndGetUserId(anyString());
    }

    /**
     * 场景三a：非 Bearer 方案（如 "Basic ..."）→ 40101。
     *
     * @return void；断言失败即非 Bearer 方案未被拒绝
     */
    @Test
    void nonBearerSchemeThrowsUnauthorized() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Basic dXNlcjpwYXNz");
        MockHttpServletResponse response = new MockHttpServletResponse();

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景三b：Bearer 后为空字符串 → 40101。
     *
     * @return void；断言失败即空 Token 未被拒绝
     */
    @Test
    void emptyBearerTokenThrowsUnauthorized() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Bearer ");
        MockHttpServletResponse response = new MockHttpServletResponse();

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景三c：无效签名 Token（verifier 抛 40101）→ 异常上抛，上下文为空。
     * 验证拦截器不吞异常、不降级。
     *
     * @return void；断言失败即异常被拦截器吞掉了
     */
    @Test
    void invalidTokenPropagatesUnauthorizedException() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Bearer bad-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(jwtVerifier.verifyAndGetUserId("bad-token"))
                .thenThrow(BizException.of(ErrorCode.UNAUTHORIZED));

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
        // 验证上下文未被污染（异常路径不写上下文）
        assertThat(AuthContext.currentUserId(request)).isNull();
    }

    /**
     * 场景四：Token 在黑名单（verifier 抛 40101）→ 40101（同无效签名，错误码相同，
     * 客户端无法区分是「签名错」还是「已登出」——安全侧不泄露原因）。
     *
     * @return void；断言失败即黑名单异常未正确上抛
     */
    @Test
    void blacklistedTokenThrowsUnauthorized() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Bearer blacklisted-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(jwtVerifier.verifyAndGetUserId("blacklisted-token"))
                .thenThrow(BizException.of(ErrorCode.UNAUTHORIZED));

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景五：Redis 查询抛异常（verifier 抛 50001）→ 50001 上抛（KTD7 红线）。
     *
     * @return void；断言失败即 Redis 故障被降级为 40101 或放行
     */
    @Test
    void redisFailurePropagatesInternalError() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("Authorization", "Bearer any-token");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(jwtVerifier.verifyAndGetUserId("any-token"))
                .thenThrow(BizException.of(ErrorCode.INTERNAL_ERROR));

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.INTERNAL_ERROR));
    }

    /**
     * 场景六：带无效 Token 的「匿名接口」请求 → 40101（KTD3：全路径生效，
     * 不因为接口是匿名的就降级游客）。拦截器不知道哪些是匿名接口，它对所有
     * 带 Token 的请求都执行验证——这是 KTD3 的本质。
     *
     * @return void；断言失败即对匿名接口路径做了特殊放行
     */
    @Test
    void invalidTokenOnAnonymousPathStillThrowsUnauthorized() {
        // 匿名接口（如 /categories、/map/pins）路径上带无效 Token
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/categories");
        request.addHeader("Authorization", "Bearer invalid-on-anon-path");
        MockHttpServletResponse response = new MockHttpServletResponse();
        when(jwtVerifier.verifyAndGetUserId("invalid-on-anon-path"))
                .thenThrow(BizException.of(ErrorCode.UNAUTHORIZED));

        assertThatThrownBy(() -> interceptor.preHandle(request, response, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }
}
