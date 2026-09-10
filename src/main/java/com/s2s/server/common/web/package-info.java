/**
 * web 横切承载包。
 *
 * <p>职责：承载 {@code ApiResponse} record 与全局 web 层组件：
 * {@code ResponseBodyWrapper}（全系统唯一响应套壳与 {@code request_id} 注入处，
 * controller 直接返 DTO、禁手写 {@code ApiResponse.ok(...)}）；
 * {@code GlobalExceptionHandler}（唯一异常→错误码映射处，亦是全系统唯一写
 * {@code Retry-After} 响应头的位置）。</p>
 *
 * <p>出处：详设 §2.1（响应包）、§2.2（异常映射）、§1.2（包结构清单）。</p>
 */
package com.s2s.server.common.web;
