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

    /** 埋点月表行数迁移阈值（行）。<b>依据源：可观测性架构方案 §9.1 阈值 T1</b>
     * （「埋点表超 2000 万行」）。消费方：可观测性阈值巡检任务。 */
    public static final long MIGRATION_TRACK_ROWS = 20_000_000L;

    /** 埋点库占盘迁移阈值（GB）。<b>依据源：可观测性架构方案 §9.1 阈值 T1</b>
     * （「埋点数据自身占盘超 8GB」）；§9.1 同时明写必须只量埋点库、不得用 {@code df}。
     * 消费方：可观测性阈值巡检任务。 */
    public static final double MIGRATION_TRACK_STORAGE_GB = 8.0;

    /** 埋点写入 QPS 迁移阈值（事件/秒）。<b>依据源：可观测性架构方案 §9.1 阈值 T2</b>
     * （「埋点写入 QPS 持续超 50」）。单分钟计数阈值 = 本值 × 60，由消费方现算，
     * 不在此预乘（预乘值散落即复制字面量）。消费方：可观测性阈值巡检任务。 */
    public static final long MIGRATION_TRACK_QPS = 50L;

    /** 高位分钟数门槛（分钟）。<b>依据源：可观测性架构方案 §9.1 阈值 T2</b>
     * （「该计数 ≥ 60 才算命中」——单分钟峰值不算，取 MAX 会让一次活动或离线回灌误触发）。
     * 消费方：可观测性阈值巡检任务。 */
    public static final long MIGRATION_HIGH_VOLUME_MINUTES = 60L;

    /** 迁移阈值的统计窗口（天）。<b>依据源：可观测性架构方案 §9.1 阈值 T2</b>（「近 7 天」）。
     * 消费方：可观测性阈值巡检任务。 */
    public static final int MIGRATION_WINDOW_DAYS = 7;

    /** 主看板 SQL 单次执行时长阈值（秒）。<b>依据源：可观测性架构方案 §9.1 阈值 T3</b>
     * （「单次执行超 10 秒」）。消费方：可观测性阈值巡检任务（当前因看板 SQL 清单
     * 文件未交付而不可执行，见该任务注释与说明文档 §2.9）。 */
    public static final long MIGRATION_DASHBOARD_SQL_SECONDS = 10L;
}
