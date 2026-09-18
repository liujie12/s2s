/**
 * 认证域。
 *
 * <p>职责：手机号 + 验证码登录、Token 签发/续期、JWT 验签与黑名单校验。
 * 域内分层固定 {@code controller/service/mapper/entity/dto}；横切件
 * {@link com.s2s.server.auth.AuthInterceptor} 与 {@link com.s2s.server.auth.JwtVerifier}
 * 属本域能力（[122] U3 落地的鉴权骨架），由 {@code config.WebCrosscutConfig}
 * 组装注册，不在本域内自行注册横切件（详设 §1.3「common 只被依赖、组装在 config」）。
 * 与前端 {@code lib/features/auth/} 同名同构。</p>
 *
 * <p>出处：详设 §1.3（分层与域边界）、§1.2（包结构清单）、§3.1（横切链序）。</p>
 */
package com.s2s.server.auth;
