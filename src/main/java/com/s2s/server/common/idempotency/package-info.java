/**
 * 幂等横切包。
 *
 * <p>职责：全系统<b>唯一</b>幂等判定与响应捕获处（编码规范 §1.2 唯一实现处清单）。
 * 组件两件，分层协作（架构评审 P0 修正）：
 * <ul>
 *   <li>{@link com.s2s.server.common.idempotency.IdempotencyInterceptor} ——
 *       纯判定件：{@code Idempotency-Key} UUID v4 校验、键维度分流（KTD13）、
 *       Redis SETNX 占位、轮询重放（KTD4），结果写入请求属性；</li>
 *   <li>{@link com.s2s.server.common.idempotency.IdempotencyCaptureFilter} ——
 *       Filter 层响应捕获：成功 SET 覆盖占位、失败 DEL、重放原样写出，
 *       末尾必调 {@code copyBodyToResponse()}。</li>
 * </ul>
 *
 * <p>横切链顺序固定为 RequestIdFilter → AuthInterceptor → RateLimitInterceptor →
 * IdempotencyInterceptor → Controller（限流必先于幂等）。幂等只看「重复相同 Key」
 * 不看请求体差异；「防同一用户刷不同 Key」的滥用面由限频轨钳制（详设 §3.3 边界句）。</p>
 *
 * <p>出处：详设 §3.3（幂等）、§3.1（横切链）、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：随条目 [122] U5 落地（原计划 [124] 前移，session-settled KTD1）。</p>
 */
package com.s2s.server.common.idempotency;
