package com.s2s.server.common.constants;

/**
 * §6.11 T1 匹配常量——Dart 真源 {@code lib/nfr_constants.dart} 的 {@code NfrMatch} 类的
 * Java 镜像（编码规范 §3.1：跨端同口径常量双端各一份，靠对账断言保证一致）。
 *
 * <p>本类只承载 <b>Java 侧实际消费</b>的成员（综合排序的权重、完整度档系数、归一化上界）。
 * Dart 侧另有 Hard Filter 类目粒度、三级类目相关性系数、单类目样本门槛等成员；
 * 服务端目前无消费方，暂不镜像——避免为不存在的消费方预建镜像（编码规范 §1.1 反冗余）。</p>
 *
 * <p>改动纪律：本类任一常量改动，必须同时改 {@code lib/nfr_constants.dart} 的
 * {@code NfrMatch} 对应成员与 PRD 对应行，缺一即视为未改。</p>
 *
 * <p>出处：PRD §6.11（阶段 0 规则加权唯一口径，2026-10-12 裁定）/ §6.12。</p>
 */
public final class NfrMatch {

    /** 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。 */
    private NfrMatch() {
    }

    /** 阶段 0 规则加权权重：时效 40%。PRD §6.11 唯一口径（2026-10-12 裁定）。
     * 消费方：{@code MapService.compositeScore}。 */
    public static final double COMPOSITE_WEIGHT_TIME = 0.40;

    /** 阶段 0 规则加权权重：距离 40%。PRD §6.11 唯一口径（2026-10-12 裁定）。 */
    public static final double COMPOSITE_WEIGHT_DISTANCE = 0.40;

    /** 阶段 0 规则加权权重：完整度档 20%。PRD §6.11 唯一口径（2026-10-12 裁定）。 */
    public static final double COMPOSITE_WEIGHT_COMPLETENESS = 0.20;

    /** 完整度档折算系数 🟢。PRD §6.11 供给分模型同源。 */
    public static final double COMPLETENESS_FACTOR_GREEN = 1.0;

    /** 完整度档折算系数 🟡。 */
    public static final double COMPLETENESS_FACTOR_YELLOW = 0.5;

    /** 完整度档折算系数 🔴。 */
    public static final double COMPLETENESS_FACTOR_RED = 0.2;

    /** 综合排序距离归一化上界（米）：范围最大档 10km 的一倍余量，与客户端同口径（原 {@code MapService} 私有常量上浮）。 */
    public static final int COMPOSITE_MAX_DISTANCE_M = 20000;

    /** 综合排序时效归一化上界（分钟）：7 天，与 PRD §6.4.4 兜底口径一致。 */
    public static final long COMPOSITE_MAX_AGE_MINUTES = 7L * 24 * 60;

    /**
     * 契约 {@code completeness_level}（0=🔴 / 1=🟡 / 2=🟢）→ 完整度档折算系数。
     *
     * <p>本映射收在常量类内：它是「契约档位 → 系数」的唯一桥。Dart 侧同职责由
     * {@code CompletenessLevel.fromApi} 承担；服务端无对应枚举，故在此实现，
     * 避免各消费方自写一份 0/1/2 语义（编码规范 §1.1）。</p>
     *
     * @param code 契约 {@code completeness_level}（DB GENERATED 列，取值 0/1/2）
     * @return 完整度档折算系数（🟢 1.0 / 🟡 0.5 / 🔴 0.2）
     * @throws IllegalArgumentException 契约外取值（服务端违约，不猜默认档）
     */
    public static double completenessFactor(int code) {
        return switch (code) {
            case 2 -> COMPLETENESS_FACTOR_GREEN;
            case 1 -> COMPLETENESS_FACTOR_YELLOW;
            case 0 -> COMPLETENESS_FACTOR_RED;
            default -> throw new IllegalArgumentException("未知 completeness_level: " + code);
        };
    }
}
