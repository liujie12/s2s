/**
 * 认证域。
 *
 * <p>职责：手机号 + 验证码登录、Token 签发/续期。域内分层固定
 * {@code controller/service/mapper/entity/dto}；与前端
 * {@code lib/features/auth/} 同名同构。</p>
 *
 * <p>出处：详设 §1.3（分层与域边界）、§1.2（包结构清单）。</p>
 */
package com.s2s.server.auth;
