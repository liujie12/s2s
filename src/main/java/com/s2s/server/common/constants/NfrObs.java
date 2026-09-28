package com.s2s.server.common.constants;

/**
 * 可观测性 NFR 常量——<b>服务端单端正源</b>，逐值抄录自《可观测性架构方案》§4.2.2。
 *
 * <p><b>为什么不是 Dart 镜像（例外登记）</b>：Dart 真源 {@code lib/nfr_constants.dart}
 * 无对应常量类——重启预热窗口由<b>服务端启动时自写</b>（详设 §21 缺口 #1：客户端不知道
 * 服务端何时重启，写入动作只在服务端），Dart 端无消费方，故本类以可观测性架构方案
 * §4.2.2 为真源直接抄录。此例外按编码规范 §3.1 登记（同
 * {@link RateLimitThresholds} 的服务端单端范式）。</p>
 *
 * <p><b>改动纪律</b>：本类任一常量改动，必须同时改可观测性架构方案 §4.2.2 对应句与
 * 消费方 {@code com.s2s.server.common.observability.RestartWindowWriter} 的测试断言，
 * 缺一即视为未改。</p>
 *
 * <p>出处：可观测性架构方案 §4.2.2（重启窗口排除的可判定形式）；详设 §21 缺口 #1。</p>
 */
public final class NfrObs {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private NfrObs() {
    }

    /** 重启预热窗口时长（分钟）。<b>依据源：可观测性架构方案 §4.2.2</b>——「应用启动时
     * 自身写入一行，{@code end_at} = 启动完成时刻 + 5 分钟」，用于 P95 分母剔除发版重启
     * 窗口与重启后预热期。消费方：{@code RestartWindowWriter} 以「启动完成时刻 +
     * 本时长」算出 {@code restart_window.end_at}。 */
    public static final long RESTART_WARMUP_MINUTES = 5;
}
