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
 * <p>子包 {@code common.audit.mapper} 承载 {@code AuditLogMapper}：包路径须以
 * {@code .mapper} 结尾才能被 {@code @MapperScan("com.s2s.server.**.mapper")} 扫到，
 * 这是启动期硬约束而非风格偏好（[128] code review 实测确证）。</p>
 *
 * <p>落地说明：{@code AuditLogWriter}/{@code AuditEntry}/{@code OperatorRole} 随条目
 * [128] contact 域落地（[125] 仅建本包占位）；本次落地同时删除了 {@code CryptoFacade}
 * 里的占位审计实现，改由调用方在同事务内调 {@code AuditLogWriter}。</p>
 */
package com.s2s.server.common.audit;
