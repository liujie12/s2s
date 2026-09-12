/**
 * 联系域。
 *
 * <p>职责：联系方式查看（{@code GET /posts/{id}/contact}）。本域含
 * {@code CryptoFacade.decrypt} 的 Batch1 唯一调用点
 * {@code ContactService#viewContact}（条目 [125]），每次解密同步同事务写
 * {@code audit_log}；联系方式明文不缓存、不写日志、不进埋点。
 * 域内分层固定 {@code controller/service/mapper/entity/dto}；与前端
 * {@code lib/features/contact/} 同名同构。</p>
 *
 * <p>出处：详设 §4（加解密，唯一调用点）、§1.3（分层与域边界）、§1.2（包结构清单）。</p>
 */
package com.s2s.server.contact;
