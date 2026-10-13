package com.s2s.server.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.AdminInterceptor;
import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.common.idempotency.IdempotencyInterceptor;
import com.s2s.server.common.ratelimit.RateLimitInterceptor;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.config.annotation.InterceptorRegistration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;

/**
 * {@link WebCrosscutConfig} 拦截器注册序测试（[122] U7；详设 §3.1 链序定死；
 * [153] 追加后台拦截器后同步）。
 *
 * <p>直接实例化真实配置类并捕获 {@link InterceptorRegistry#addInterceptor} 的调用顺序，
 * 断言注册序为 {@code AuthInterceptor → AdminInterceptor → RateLimitInterceptor →
 * IdempotencyInterceptor}（限流必先于幂等，鉴权必先于限流；后台拦截器独立成位、只拦
 * {@code /admin/**}）。这避免集成测试手拼链序对生产配置类错误免疫——手拼链序若与
 * {@code WebCrosscutConfig} 不一致，本测试直接锚定真实注册序守门（计划 U7）。</p>
 *
 * <p>测试策略：拦截器与 Redis 模板全用 Mockito mock；{@code addInterceptor} 返回的
 * {@link InterceptorRegistration} 亦需 stub（生产代码对其链式调用
 * {@code excludePathPatterns}/{@code addPathPatterns}，未 stub 会取到 null 而 NPE）。</p>
 */
class WebCrosscutConfigOrderTest {

    /**
     * 断言拦截器注册序恰为 Auth → Admin → RateLimit → Idempotency（含恰好 4 次注册）。
     *
     * @return void；断言失败即注册序漂移（链序错位是限流/幂等失效的高危缺陷）
     */
    @Test
    void addInterceptorsRegistersAuthThenAdminThenRateLimitThenIdempotency() {
        AuthInterceptor auth = mock(AuthInterceptor.class);
        AdminInterceptor admin = mock(AdminInterceptor.class);
        RateLimitInterceptor rateLimit = mock(RateLimitInterceptor.class);
        IdempotencyInterceptor idempotency = mock(IdempotencyInterceptor.class);
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        WebCrosscutConfig config =
                new WebCrosscutConfig(auth, admin, rateLimit, idempotency, redis);

        InterceptorRegistry registry = mock(InterceptorRegistry.class);
        InterceptorRegistration registration = mock(InterceptorRegistration.class);
        when(registry.addInterceptor(any())).thenReturn(registration);
        when(registration.excludePathPatterns(any(String[].class))).thenReturn(registration);
        when(registration.addPathPatterns(any(String[].class))).thenReturn(registration);

        config.addInterceptors(registry);

        ArgumentCaptor<HandlerInterceptor> captor = ArgumentCaptor.forClass(HandlerInterceptor.class);
        verify(registry, times(4)).addInterceptor(captor.capture());
        assertThat(captor.getAllValues())
                .as("拦截器注册序须为 Auth → Admin → RateLimit → Idempotency（详设 §3.1 + [153]）")
                .containsExactly(auth, admin, rateLimit, idempotency);
    }
}
