package com.s2s.server.common.constants;

/**
 * 性能 NFR 常量——Dart 真源 {@code lib/nfr_constants.dart} 的 {@code NfrPerf} 类的
 * Java 镜像（编码规范 §3.1：跨端同口径常量双端各一份，靠对账断言保证一致）。
 *
 * <p>本类只承载 map 域（[126]）实际消费的三项性能常量，其余 {@code NfrPerf} 成员
 * （{@code layerSwitchP95Ms} 等）无 Java 侧消费方，暂不镜像——避免为不存在的消费方
 * 预建镜像（编码规范 §1.1 反冗余）。</p>
 *
 * <p>改动纪律：本类任一常量改动，必须同时改 {@code lib/nfr_constants.dart} 的
 * {@code NfrPerf} 对应成员与 PRD 对应行，缺一即视为未改。</p>
 *
 * <p>出处：PRD §14.1 / §12.1（传输层约定）/ §6.10（地图取数）。</p>
 */
public final class NfrPerf {

    /** 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。 */
    private NfrPerf() {
    }

    /** 单次渲染 Pin 数上限。PRD §14.1 / §6.7 / §6.8；值从 Dart 真源
     * {@code NfrPerf.renderMaxPins} 抄录（2026-09-23 核对现行值 500）。
     * 消费方：{@code /map/pins} 覆盖索引查询的 {@code LIMIT} 与紧凑序列化条数。 */
    public static final int RENDER_MAX_PINS = 500;

    /** {@code /map/pins} 响应坐标的小数位数。PRD §12.1 坐标行；值从 Dart 真源
     * {@code NfrPerf.mapPinCoordDecimals} 抄录（5 位约 1m 精度）。消费方：紧凑序列化
     * 坐标截位（详情页/发布接口仍用 6 位，不在本类）。 */
    public static final int MAP_PIN_COORD_DECIMALS = 5;

    /** 服务端预聚合与客户端聚合的切换阈值（米/像素）。PRD §12.3；值从 Dart 真源
     * {@code NfrPerf.clusterModeSwitchMetersPerPixel} 抄录（现值 30）。
     * 消费方：{@code /map/pins} 由 zoom 换算 metersPerPixel 后与本值比较，决定
     * {@code mode=cluster}（远景，服务端预聚合）还是 {@code mode=pin}（近景，客户端聚合）。 */
    public static final double CLUSTER_MODE_SWITCH_METERS_PER_PIXEL = 30;
}
