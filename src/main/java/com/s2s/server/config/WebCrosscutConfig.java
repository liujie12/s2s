package com.s2s.server.config;

import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.common.idempotency.IdempotencyCaptureFilter;
import com.s2s.server.common.idempotency.IdempotencyInterceptor;
import com.s2s.server.common.ratelimit.RateLimitInterceptor;
import com.s2s.server.common.web.RequestIdFilter;
import jakarta.servlet.DispatcherType;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * 横切链<b>组装根</b>（[122] KTD9）：全部横切件（Filter 与拦截器）的注册落点，注册顺序即
 * 执行顺序，定死为 {@code RequestIdFilter → AuthInterceptor → RateLimitInterceptor →
 * IdempotencyInterceptor → Controller}（详设 §3.1，限流必先于幂等）。
 *
 * <p>Filter 与拦截器分层：
 * <ul>
 *   <li><b>Filter 层</b>（Servlet 层，先于 DispatcherServlet）：RequestIdFilter
 *       （链首，注入 request_id/MDC/访问日志）、IdempotencyCaptureFilter（U5，响应体捕获）。
 *       通过 {@link FilterRegistrationBean} 显式注册，order 精确控制，避免
 *       Spring Boot 自动注册 Filter bean 导致链序漂移。</li>
 *   <li><b>拦截器层</b>（Spring MVC 层，handler 前后）：AuthInterceptor（U3）、
 *       RateLimitInterceptor（U4）、IdempotencyInterceptor（U5）。
 *       经 {@link WebMvcConfigurer#addInterceptors} 按 add 顺序注册，顺序即执行顺序。</li>
 * </ul>
 *
 * <p>依赖方向：config 是组装根，依赖 common/auth 等域的横切组件，
 * 维持「common 只被依赖」（详设 §1.3）。
 */
@Configuration
public class WebCrosscutConfig implements WebMvcConfigurer {

    /** 鉴权拦截器（构造注入，Spring 托管的单例）。 */
    private final AuthInterceptor authInterceptor;

    /** 限频拦截器（构造注入，Spring 托管的单例）。 */
    private final RateLimitInterceptor rateLimitInterceptor;

    /** 幂等判定拦截器（构造注入，Spring 托管的单例）。 */
    private final IdempotencyInterceptor idempotencyInterceptor;

    /** Redis 模板（供幂等捕获 Filter 显式实例化，非拦截器用——拦截器各自注入）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造组装根，注入全部拦截器与 Redis 模板。
     *
     * @param authInterceptor       鉴权拦截器（auth 域 @Component）
     * @param rateLimitInterceptor  限频拦截器（common/ratelimit 域 @Component）
     * @param idempotencyInterceptor 幂等拦截器（common/idempotency 域 @Component）
     * @param redisTemplate         Redis 模板（幂等捕获 Filter 实例化参数）
     */
    public WebCrosscutConfig(AuthInterceptor authInterceptor,
            RateLimitInterceptor rateLimitInterceptor,
            IdempotencyInterceptor idempotencyInterceptor,
            StringRedisTemplate redisTemplate) {
        this.authInterceptor = authInterceptor;
        this.rateLimitInterceptor = rateLimitInterceptor;
        this.idempotencyInterceptor = idempotencyInterceptor;
        this.redisTemplate = redisTemplate;
    }

    /**
     * 注册 {@link RequestIdFilter}：最高优先级（链首铁位）+ 仅 REQUEST 派发。
     * 显式 {@code new} 而非注入 {@code Filter} bean——避免 Spring Boot 对 Filter 类型
     * bean 的自动注册（自动注册不带 order/派发面约束，会绕过本处的链序定死口径）。
     *
     * @return {@link FilterRegistrationBean} 携带已定位的 RequestIdFilter 注册描述
     */
    @Bean
    public FilterRegistrationBean<RequestIdFilter> requestIdFilterRegistration() {
        FilterRegistrationBean<RequestIdFilter> registration =
                new FilterRegistrationBean<>(new RequestIdFilter());
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE);
        registration.setDispatcherTypes(DispatcherType.REQUEST);
        return registration;
    }

    /**
     * 注册 {@link IdempotencyCaptureFilter}：紧随 RequestIdFilter 之后（HIGHEST + 1）、
     * 仅 REQUEST 派发。响应体捕获必须在 Filter 层先于 DispatcherServlet 包装 response
     * （架构评审 P0），故 order 紧邻 RequestIdFilter 之后、其余任何 Filter 之前。
     *
     * @return {@link FilterRegistrationBean} 携带已定位的幂等捕获 Filter 注册描述
     */
    @Bean
    public FilterRegistrationBean<IdempotencyCaptureFilter> idempotencyCaptureFilterRegistration() {
        FilterRegistrationBean<IdempotencyCaptureFilter> registration =
                new FilterRegistrationBean<>(new IdempotencyCaptureFilter(redisTemplate));
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE + 1);
        registration.setDispatcherTypes(DispatcherType.REQUEST);
        return registration;
    }

    /**
     * 注册拦截器链：按 add 顺序 = 执行顺序（详设 §3.1 链序定死：
     * AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor）。
     *
     * <p><b>全路径生效</b>：不加 excludePathPatterns——具体哪些接口启用哪些限频轨/幂等
     * 由方法上的 {@code @RateLimit}/{@code @Idempotent} 注解声明，拦截器对无注解的方法
     * 直接放行。
     *
     * @param registry Spring MVC 拦截器注册器
     */
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(authInterceptor);
        registry.addInterceptor(rateLimitInterceptor);
        registry.addInterceptor(idempotencyInterceptor);
    }
}
