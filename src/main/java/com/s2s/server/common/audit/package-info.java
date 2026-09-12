/**
 * 审计包。
 *
 * <p>职责：承载 {@code AuditLogWriter}（全系统唯一 {@code audit_log} 写入处）。
 * 每次解密经 {@code CryptoFacade} 同步同事务写审计；审计白名单剔除
 * {@code phone}/{@code real_name}/{@code id_card}/{@code contact_value}/
 * {@code *_enc}/{@code *_hash}；{@code audit_log} 与 {@code contact_event}
 * 职责不同、不互替。</p>
 *
 * <p>出处：详设 §4（加解密与审计）、可观测 §4、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：组件随条目 [125] 落地，本条目（U-2）仅建包占位。</p>
 */
package com.s2s.server.common.audit;
