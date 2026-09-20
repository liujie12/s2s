package com.s2s.server.common.idempotency;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * 写接口幂等标注（消费方 {@code IdempotencyInterceptor}，[122] U5）。
 *
 * <p>标注本注解的接口进入幂等判定：校验 {@code Idempotency-Key} 头（v4 UUID 正则，
 * 缺失/大写/v1 返 {@code 40001} 不放行）→ Redis SETNX 占位 → 首次成功响应完整缓存
 * （TTL {@code NfrApi.IDEMPOTENCY_WINDOW_HOURS}）→ 并发/重放轮询原样返回首次结果。
 * 不标注即豁免（如 {@code POST /posts/precheck} 不写库，契约守门以「不标注」佐证豁免）。</p>
 *
 * <p>出处：详设 §3.3（幂等）、§3.1（横切链位次：限流之后）；键维度分流见
 * {@link #anonymous()}（计划 [122] KTD13）。</p>
 */
@Documented
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Idempotent {

    /**
     * 是否匿名写接口（KTD13）：区分两类幂等键维度。
     *
     * <p>{@code true}——openapi 声明 {@code security: []} 且契约必带
     * {@code Idempotency-Key} 的接口（{@code POST /auth/sms/send}、
     * {@code POST /auth/sms/login}）：无 userId 可用，键为
     * {@code idem:dev:{X-Device-Id}:{key}}，缺设备头降级 {@code idem:anon:{key}}；
     * 滥用面由链序双重钳制（限流在幂等之前 + 仅成功响应驻留缓存，失败即 DEL）。</p>
     *
     * <p>{@code false}（默认）——登录态写接口：键为 {@code idem:{userId}:{key}}，
     * 无鉴权上下文返 {@code 40101}（与 openapi security 声明逐一对齐）。</p>
     *
     * @return boolean；{@code true} 走匿名键维度，{@code false}（默认）要求登录态
     */
    boolean anonymous() default false;
}
