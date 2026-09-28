/**
 * 联系域。
 *
 * <p>职责：联系方式查看（{@code GET /posts/{id}/contact}）与举报
 * （{@code POST /posts/{id}/report}）。本域含 {@code CryptoFacade} 解密方法的
 * Batch1 唯一调用点 {@code ContactService#viewContact}（[128] 落地）——
 * 该调用点由静态守门测试 {@code CryptoFacadeCallSiteTest}（全库解密调用计数 == 1）
 * 钉死，新增即架构变更须评审。
 * 联系方式明文不缓存、不写日志、不进埋点（安全 §3、详设 §20.1 纪律 2）。</p>
 *
 * <p><b>两张表的职责不互替</b>（详设 §5.5.1、可观测 §5）：
 * {@code contact_event} 是北极星辅助指标的<b>唯一统计点</b>；
 * {@code audit_log} 是合规举证的<b>唯一来源</b>（180 天、必须与业务同事务）。
 * 同一次「查看联系方式」产生两条记录，不是重复写入。</p>
 *
 * <p><b>限频为何是命令式而非注解式</b>：详设 §5.5.1 给出的是有序链路
 * （冻结 → 三维日限 → 突发 → 可见性 → 解密 → 双写），次序本身是规格，
 * 由 {@code ContactRateGuard} 编排；计数仍只经 {@code RateLimiter}（唯一计数处）。</p>
 *
 * <p>域内分层固定 {@code controller/service/mapper/entity/dto}；与前端
 * {@code lib/features/contact/} 同名同构。</p>
 *
 * <p>出处：详设 §4（加解密，唯一调用点）、§5.5（本域两接口）、§1.3（分层与域边界）、
 * §1.2（包结构清单）。</p>
 */
package com.s2s.server.contact;
