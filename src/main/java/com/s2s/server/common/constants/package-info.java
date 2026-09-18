/**
 * 后端 NFR 数字常量包（常量真源，编码规范 §3.1 / 详设 §0.1「不复制字面量」）。
 *
 * <p>职责：承载阈值、TTL、窗口秒数、批次大小等横切链与接口层 NFR 数字的
 * {@code static final} 常量，业务代码一律引用常量名，禁止内联字面量。</p>
 *
 * <p>真源分工（两类，落包时逐一注明）：</p>
 * <ul>
 *   <li>跨端同口径（如 {@link com.s2s.server.common.constants.NfrApi}）：
 *       真源为 Dart 端 {@code lib/nfr_constants.dart}，本包为 Java 镜像，
 *       值逐值抄录并注 PRD 章节号，靠双端对账测试保证一致
 *       （编码规范 §1.1 第 2 条：跨端镜像双端各有唯一实现处，不算冗余）；</li>
 *   <li>服务端单端口径（如 {@link com.s2s.server.common.constants.RateLimitThresholds}）：
 *       Dart 真源无对应常量类（客户端被禁止本地预测剩余次数，无消费方），
 *       以详设表格为真源直接抄录——此例外已在编码规范 §3.1 登记
 *       （计划 [122] KTD11）。</li>
 * </ul>
 *
 * <p>出处：编码规范 §3.1（常量真源）、详设 §0.1（三条全局硬纪律）、
 * 详设 §3.3（幂等）/§3.4（限频）；包结构清单见详设 §1.2。</p>
 */
package com.s2s.server.common.constants;
