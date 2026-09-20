package com.s2s.server.common.constants;

/**
 * 接口层 NFR 常量——Dart 真源 {@code lib/nfr_constants.dart} 的 {@code NfrApi} 类的
 * Java 镜像（编码规范 §3.1：跨端同口径常量双端各一份，靠对账断言保证一致）。
 *
 * <p><b>为什么需要镜像类</b>（计划 [122] KTD11）：分页与幂等窗口在 PRD §12 中是
 * 双端口径（客户端 dio 层与服务端 controller/拦截器层都要引用），按「不复制字面量」
 * 硬纪律（详设 §0.1），Java 侧消费方必须引用常量名而非手敲数字，故建本镜像。
 * 本条目（[122] U1）的首个消费方是幂等键 TTL（{@link #IDEMPOTENCY_WINDOW_HOURS}），
 * 其余三项随各自消费方（分页参数校验、埋点批次校验）落地时引用。</p>
 *
 * <p><b>改动纪律</b>（与 Dart 真源头注释对称）：本类任一常量改动，必须同时改
 * {@code lib/nfr_constants.dart} 的 {@code NfrApi} 对应成员与 PRD 对应行，缺一即视为未改
 * ——否则真源变成两个，比没有真源更糟。</p>
 *
 * <p>出处：PRD §12.1（传输层约定）/ §12.4（埋点上报）；详设 §0.1（不复制字面量）、
 * §3.3（幂等 TTL 消费方）。</p>
 */
public final class NfrApi {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private NfrApi() {
    }

    /** 列表分页默认页大小。PRD §12.1；值从 Dart 真源 {@code NfrApi.pageSizeDefault} 抄录
     * （2026-09-18 核对现行值 20）。 */
    public static final int PAGE_SIZE_DEFAULT = 20;

    /** 列表分页页大小上限。PRD §12.1（编码规范 §4.12「page_size 默认 20 上限 50」）；
     * 值从 Dart 真源 {@code NfrApi.pageSizeMax} 抄录（2026-09-18 核对现行值 50）。 */
    public static final int PAGE_SIZE_MAX = 50;

    /**
     * 写接口幂等键的服务端记忆窗口（小时）。PRD §12.1；值从 Dart 真源
     * {@code NfrApi.idempotencyWindowHours} 抄录（2026-09-18 核对现行值 24）。
     *
     * <p>消费口径：Redis 键 {@code idem:{userId}:{key}} 的 TTL，服务端 24h 内重复键
     * 直接返回首次结果（详设 §3.3）。秒数换算由消费方用
     * {@code Duration.ofHours(NfrApi.IDEMPOTENCY_WINDOW_HOURS)} 完成，本类不提供
     * 预乘的秒常量——预乘值（24*3600）一旦散落即复制字面量。</p>
     */
    public static final int IDEMPOTENCY_WINDOW_HOURS = 24;

    /** 埋点批量上报单次条数上限。PRD §12.4；值从 Dart 真源
     * {@code NfrApi.trackBatchMaxEvents} 抄录（2026-09-18 核对现行值 50）。
     * 服务端消费方：单请求 ≤50 事件校验（超限 42906，详设 §3.4 埋点行；
     * 校验逻辑属条目 [129]）。 */
    public static final int TRACK_BATCH_MAX_EVENTS = 50;
}
