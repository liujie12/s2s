/**
 * 限频横切包。
 *
 * <p>职责：全系统<b>唯一</b>限频计数与键命名处（编码规范 §1.2 唯一实现处清单）。
 * 组件四件：
 * <ul>
 *   <li>{@link com.s2s.server.common.ratelimit.RateLimitKeys} —— Redis 键唯一拼装处，
 *       类型分维防串用（账号维 Long、渠道维 String phone/ip、设备维 deviceId + 格式校验）；</li>
 *   <li>{@link com.s2s.server.common.ratelimit.RateLimiter} —— Lua 原子 INCR+EXPIRE，
 *       多轨 max 取最长剩余秒，Redis 写失败记 WARN 放行（防滥用非账务）；</li>
 *   <li>{@link com.s2s.server.common.ratelimit.RateLimitInterceptor} —— 声明式
 *       {@code @RateLimit} 注解驱动的拦截器，注册于鉴权之后、幂等之前；</li>
 *   <li>{@link com.s2s.server.common.ratelimit.RateLimitTrack} —— 11 行键表的编译期桥，
 *       逐轨绑定阈值/窗口/超限码三元组，引用常量零字面量。</li>
 * </ul>
 *
 * <p>纪律：账号级限频一律 {@code user_id}；渠道级（短信、登录失败）未登录无
 * {@code user_id} 时保留手机号/IP 维度；限频响应不区分命中维度，
 * {@code 429} 段与 {@code 40105} 必带整数秒 {@code Retry-After}——<b>唯一写头
 * 位置在 {@code GlobalExceptionHandler}</b>，本包任何类禁直写响应头。</p>
 *
 * <p>出处：详设 §3.4（限频）、§3.1（横切链序：鉴权→限流→幂等）、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：随条目 [122] U4 落地（原计划 [124] 前移，session-settled KTD1）。</p>
 */
package com.s2s.server.common.ratelimit;
