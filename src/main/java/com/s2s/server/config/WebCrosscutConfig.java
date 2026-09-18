package com.s2s.server.config;

import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.common.web.RequestIdFilter;
import jakarta.servlet.DispatcherType;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
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

    /**
     * 构造组装根，注入所有拦截器（当前仅 AuthInterceptor，U4/U5 后续追加）。
     *
     * @param authInterceptor 鉴权拦截器（auth 域 @Component）
     */
    public WebCrosscutConfig(AuthInterceptor authInterceptor) {
        this.authInterceptor = authInterceptor;
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
     * 注册拦截器链：按 add 顺序 = 执行顺序（详设 §3.1 链序定死）。
     * 当前（[122] U3）仅注册 AuthInterceptor；RateLimitInterceptor 与 IdempotencyInterceptor
     * 随 U4/U5 追加在此方法内。
     *
     * <p><b>全路径生效</b>：不加 excludePathPatterns——鉴权拦截器对所有请求执行，
     * 「是否需要登录」是业务层判定（40101 只是 Token 无效，和「该接口是否要登录」
     * 是两个维度）。匿名接口带无效 Token 也必须 40101（KTD3），这是默认全路径
     * 生效的直接结果，无需额外配置。
     *
     * @param registry Spring MVC 拦截器注册器
     */
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(authInterceptor);
    }
}
