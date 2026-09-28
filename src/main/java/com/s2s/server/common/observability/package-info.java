/**
 * 可观测性基础设施包（跨域）。
 *
 * <p>职责：承载与具体业务域无关的可观测性记账逻辑。当前唯一实现为
 * {@code RestartWindowWriter}——服务端启动时向业务库 {@code restart_window} 表自写一行
 * （{@code start_at} = 应用开始启动时刻、{@code end_at} = 启动完成时刻 +
 * {@code NfrObs.RESTART_WARMUP_MINUTES} 分钟），供 P95 分母剔除「发版重启窗口与重启后
 * 预热期」（可观测性架构方案 §4.2.2 的重启窗口排除规则）。</p>
 *
 * <p>出处：详设 §21 已识别缺口 #1（{@code restart_window} 表 + 服务端启动自写）；建表见
 * {@code V2__restart_window.sql}；写入语义唯一口径源为可观测性架构方案 §4.2.2。</p>
 *
 * <p>子包 {@code common.observability.mapper} 承载 {@code RestartWindowMapper}：包路径须以
 * {@code .mapper} 结尾才能被 {@code @MapperScan("com.s2s.server.**.mapper")} 扫到，
 * 这是启动期硬约束而非风格偏好（见 {@code AuditLogMapper} 类注释，由常驻门禁
 * {@code MapperScanCoverageTest} 守住）。</p>
 */
package com.s2s.server.common.observability;
