/**
 * 错误码与业务异常包。
 *
 * <p>职责：承载 {@code ErrorCode} 枚举（全系统唯一错误码定义处，共 25 枚
 * ——24 业务码 + {@code 0}，唯一口径源为 PRD §12.5，代码侧禁止占号新增）
 * 与 {@code BizException}（业务异常，取其 {@code ErrorCode} 交由
 * {@code GlobalExceptionHandler} 统一映射）。</p>
 *
 * <p>出处：详设 §2.3（错误码定义）、§1.2（包结构清单）。</p>
 */
package com.s2s.server.common.error;
