package com.s2s.server.config;

import com.s2s.server.common.web.RequestIdFilter;
import jakarta.servlet.DispatcherType;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

/**
 * 横切链<b>组装根</b>（[122] KTD9）：全部横切件（Filter 与拦截器）的注册落点，注册顺序即
 * 执行顺序，定死为 {@code RequestIdFilter → AuthInterceptor → RateLimitInterceptor →
 * IdempotencyInterceptor → Controller}（详设 §3.1，限流必先于幂等）。
 *
 * <p>本单元（[122] U2）仅注册 {@link RequestIdFilter}：
 * {@link Ordered#HIGHEST_PRECEDENCE} 保证其位于一切 Filter（含 Spring 内建）之前——
 * request_id 链首生成的语义前提；{@code DispatcherType.REQUEST} 收敛派发面
 * （ERROR 派发不重复执行，已知边界见 {@link RequestIdFilter} 类注释）。
 * 后续单元（U3/U4/U5）在此追加拦截器注册，全部经 {@code WebMvcConfigurer.addInterceptors}
 * 按 add 顺序生效，业务代码不得自行注册横切件（组装单一落点，防链序漂移）。
 *
 * <p>依赖方向：config 是组装根，依赖 common/auth 等域的横切组件，
 * 维持「common 只被依赖」（详设 §1.3）。
 */
@Configuration
public class WebCrosscutConfig {

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
}
