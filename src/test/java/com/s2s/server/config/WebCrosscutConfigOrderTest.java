package com.s2s.server.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.common.idempotency.IdempotencyInterceptor;
import com.s2s.server.common.ratelimit.RateLimitInterceptor;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;

/**
 * {@link WebCrosscutConfig} 拦截器注册序测试（[122] U7；详设 §3.1 链序定死）。
 *
 * <p>直接实例化真实配置类并捕获 {@link InterceptorRegistry#addInterceptor} 的调用顺序，
 * 断言注册序为 {@code AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor}
 * （限流必先于幂等，鉴权必先于限流）。这避免集成测试手拼链序对生产配置类错误免疫——
 * 手拼链序若与 {@code WebCrosscutConfig} 不一致，本测试直接锚定真实注册序守门（计划 U7）。
 *
 * <p>测试策略：拦截器与 Redis 模板全用 Mockito mock（本测试只关注注册顺序，不关注拦截器
 * 内部行为），经 {@link ArgumentCaptor} 捕获 {@code addInterceptor} 的实参序列。
 */
class WebCrosscutConfigOrderTest {

    /**
     * 断言拦截器注册序恰为 Auth → RateLimit → Idempotency（含恰好 3 次注册）。
     *
     * @return void；断言失败即注册序漂移（链序错位是限流/幂等失效的高危缺陷）
     */
    @Test
    void addInterceptorsRegistersAuthThenRateLimitThenIdempotency() {
        AuthInterceptor auth = mock(AuthInterceptor.class);
        RateLimitInterceptor rateLimit = mock(RateLimitInterceptor.class);
        IdempotencyInterceptor idempotency = mock(IdempotencyInterceptor.class);
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        WebCrosscutConfig config = new WebCrosscutConfig(auth, rateLimit, idempotency, redis);

        InterceptorRegistry registry = mock(InterceptorRegistry.class);
        config.addInterceptors(registry);

        ArgumentCaptor<HandlerInterceptor> captor = ArgumentCaptor.forClass(HandlerInterceptor.class);
        verify(registry, times(3)).addInterceptor(captor.capture());
        assertThat(captor.getAllValues())
                .as("拦截器注册序须为 Auth → RateLimit → Idempotency（详设 §3.1）")
                .containsExactly(auth, rateLimit, idempotency);
    }
}