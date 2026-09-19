package com.s2s.server.common.ratelimit;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 接口限频标注：声明该接口生效的限频键轨（消费方 {@code RateLimitInterceptor}，
 * [122] U4）。
 *
 * <p>值为 {@link RateLimitTrack} 数组以支持多键轨并发声明（如联系方式拉取同时挂
 * 账号/设备/IP 三轨；多轨同时超限时 {@code Retry-After} 取最长剩余秒数——计划 [122]
 * R5/KTD6）。阈值/窗口/超限码三元组由 {@link RateLimitTrack} 逐轨绑定
 * {@code RateLimitThresholds} 常量，本注解不出现任何数字。</p>
 *
 * <p>出处：详设 §3.4（限频键表 11 行）、§3.1（横切链位次：鉴权之后、幂等之前）。</p>
 */
@Documented
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RateLimit {

    /**
     * 生效的限频键轨集合。
     *
     * @return {@link RateLimitTrack} 数组；空数组无意义（不标注即不限频），
     *         多轨全量生效、任一超限即拒绝
     */
    RateLimitTrack[] value();
}
