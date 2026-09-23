package com.s2s.server.common.constants;

/**
 * 缓存层 NFR 常量——Dart 真源 {@code lib/nfr_constants.dart} 的 {@code NfrCache} 类的
 * Java 镜像（编码规范 §3.1：跨端同口径常量双端各一份，靠对账断言保证一致）。
 *
 * <p>本类承载「内容易变性分档」的 TTL 决策（[121] 缺陷第 7 条定案）：
 * 易变的 Pin 集合压到 60s，静态数据（分类树/模板）保留小时级。分类树与模板走
 * {@link #STATIC_L1_TTL_SEC} 档本地 Caffeine 缓存（详设 §5.2）。</p>
 *
 * <p>改动纪律：本类任一常量改动，必须同时改 {@code lib/nfr_constants.dart} 的
 * {@code NfrCache} 对应成员，缺一即视为未改。</p>
 *
 * <p>出处：PRD §6.10（缓存三层架构）/ §9.10.1（配置传播时限）。</p>
 */
public final class NfrCache {

    /** 私有构造器：常量类禁止实例化。 */
    private NfrCache() {
    }

    /** Pin 集合缓存 TTL（秒）。易变数据，与 PRD:1731「后台每分钟轮询 expire_at」对齐。 */
    public static final int PIN_SET_TTL_SEC = 60;

    /** 静态数据（分类树/模板等）一级 TTL（秒）。PRD §6.10 第 3 层。 */
    public static final int STATIC_L1_TTL_SEC = 3600;

    /** 静态数据二级 TTL（秒）。 */
    public static final int STATIC_L2_TTL_SEC = 900;

    /** 静态数据三级 TTL（秒）。 */
    public static final int STATIC_L3_TTL_SEC = 300;

    /** 单设备缓存键容量上限，超出按 LRU 淘汰。PRD §6.10。 */
    public static final int MAX_KEYS = 50;

    /** 缓存键中坐标网格的取整边长（米）。PRD §6.10 缓存键五要素。 */
    public static final double KEY_GRID_METERS = 500.0;

    /**
     * 运营改分类配置后客户端拉到新版本号并清缓存的时限（秒）。
     * PRD §9.10.1 后台验收标准。
     */
    public static final int CONFIG_PROPAGATE_SEC = 3;
}
