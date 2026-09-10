/**
 * 幂等横切包。
 *
 * <p>职责：承载 {@code IdempotencyInterceptor}（全系统唯一幂等判定处：
 * {@code Idempotency-Key} 正则校验、Redis {@code SETNX} 占位、首次成功响应
 * 缓存与重放原样返回）。横切链顺序固定为
 * RequestIdFilter → AuthInterceptor → RateLimitInterceptor →
 * IdempotencyInterceptor → Controller（限流必先于幂等）。</p>
 *
 * <p>出处：详设 §3.3（幂等）、§3.1（横切链）、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：组件随条目 [124] 落地，本条目（U-2）仅建包占位。</p>
 */
package com.s2s.server.common.idempotency;
