/**
 * 限频横切包。
 *
 * <p>职责：承载 {@code RateLimiter} + {@code RateLimitKeys}（全系统唯一限频
 * 计数与键命名处）。账号级限频一律用 {@code user_id}，渠道级（短信、登录失败）
 * 未登录无 {@code user_id} 时保留手机号维度；限频响应不区分命中维度，
 * {@code 429} 段与 {@code 40105} 必带整数秒 {@code Retry-After}（唯一写头
 * 位置在 {@code GlobalExceptionHandler}）。</p>
 *
 * <p>出处：详设 §3.4（限频）、§3.1（横切链）、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：组件随条目 [124] 落地，本条目（U-2）仅建包占位。</p>
 */
package com.s2s.server.common.ratelimit;
