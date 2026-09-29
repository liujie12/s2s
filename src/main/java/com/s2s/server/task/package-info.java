/**
 * 定时任务域（[129] P4 落地）。
 *
 * <p>职责：单实例 {@code @Scheduled} 定时任务，编号沿用详设 §6 原表
 * （Batch1 为 #1–#9）。调度开关见 {@code TaskSchedulingConfig}。</p>
 *
 * <p><b>单实例前提（硬要求）</b>：详设 §6 明写「单实例部署 + Spring {@code @Scheduled}，
 * 无需分布式锁；若未来扩为多实例，这 11 项必须同时引入分布式锁」。本域每个任务类的
 * 类注释均须写明此前提——扩多实例前先加锁，否则清理类任务会跨实例重复执行。</p>
 *
 * <p><b>[129] 落地状态（2026-09-29）</b>：</p>
 * <ul>
 *   <li>#1 到期帖自动下架 —— {@code PostExpireTask}</li>
 *   <li>#2 埋点月表预建 —— {@code TrackMonthTableTask#prebuildNextMonthTable}</li>
 *   <li>#3 埋点月表清理 —— {@code TrackMonthTableTask#dropExpiredMonthTables}</li>
 *   <li>#4 审计日志清理 —— {@code AuditLogCleanupTask}</li>
 *   <li>#5 中转脱敏日志清理 —— <b>未实现</b>：清理对象（日志载体）在设计文档中查无定义，
 *       已在保留策略注册表登记 key，缺口与裁定见说明文档 §2.9</li>
 *   <li>#6 取消收藏记录清理 —— {@code FavoriteCleanupTask}</li>
 *   <li>#7 注销冷静期到期清理 —— {@code DeactivateCleanupTask}（覆盖身份行 / 实名结果 /
 *       手机号掩码三步；<b>联系方式清除待裁定</b>，见该类注释与说明文档 §2.9）</li>
 *   <li>#8 可观测性阈值巡检 —— {@code ObservabilityInspectionTask}（T1/T2 可执行，
 *       T3 因主看板 SQL 清单未交付而不可执行，如实标 SKIP）</li>
 *   <li>#9 24h 未 commit 媒体孤儿清理 —— {@code MediaOrphanCleanupTask}</li>
 * </ul>
 *
 * <p>保留策略键与执行者的对应关系由 {@code common.retention.RetentionRuleRegistry} 承载，
 * 其与 PRD §13.4 的一致性由 {@code RetentionRuleCoverageTest} 守门（Batch1 R17）。</p>
 *
 * <p>出处：详设 §6（定时任务）、§1.2（包结构清单）、架构 §8（任务表）。</p>
 */
package com.s2s.server.task;
