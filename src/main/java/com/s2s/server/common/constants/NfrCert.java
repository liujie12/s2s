package com.s2s.server.common.constants;

/**
 * cert 域 NFR 常量（[149]；实名认证 + 未实名详情额度）。
 *
 * <p>职责：承载实名域的两类阈值——未实名每日详情额度（双端口径，Dart 侧镜像
 * {@code lib/nfr_constants.dart} 的 {@code NfrCert} 成员，前端拼「今日剩余」文案引用）与
 * 二要素失败锁定（服务端单端消费，前端无消费方，故不建 Dart 镜像，口径同
 * {@link RateLimitThresholds} 的「服务端单端正源」例外）。供 service 引用，禁写死数字
 * （编码规范红线「不复制字面量」）。</p>
 *
 * <p>出处：PRD §12.3（未实名每日详情额度）、PRD §4.8（二要素失败锁定）；DEC-30
 * （2026-10-11 裁定「每日 5 条详情，原 3 条」）。</p>
 */
public final class NfrCert {

    /**
     * 未实名用户每日详情浏览额度（条）。PRD §12.3「已登录未实名每日放行 5 条，第 6 条
     * 回 40301」；DEC-30 裁定原 3 条改为 5 条（2026-10-11）。双端口径：Dart 侧
     * {@code NfrCert.detailQuotaLimitPerDay} 镜像，前端弹半屏引导文案引用本值拼
     * 「今日 N 条」。
     */
    public static final int DETAIL_QUOTA_LIMIT_PER_DAY = 5;

    /**
     * 二要素核验失败锁定阈值（次）。PRD §4.8「二要素 3 次失败锁 24h，需人工申诉」。
     * 达阈值后写 {@code cert.lock_until}，锁定期间提交实名直接拒绝。
     */
    public static final int REALNAME_FAIL_LOCK_THRESHOLD = 3;

    /**
     * 二要素失败锁定时长（秒）= 24 小时。PRD §4.8。消费方（cert 域）以
     * {@code Duration.ofSeconds(NfrCert.REALNAME_FAIL_LOCK_SECONDS)} 换算，
     * 本类不提供预乘值——预乘值（24*3600）一旦散落即复制字面量。
     */
    public static final long REALNAME_FAIL_LOCK_SECONDS = 86_400;

    /**
     * 资质认证人工审核 SLA（小时）。PRD §4.5「人工审核（SLA ≤ 2h）」。资质提交响应的
     * {@code sla_hours} 字段值（[149] 资质占位阶段仍返回该值，供前端展示审核时限）。
     */
    public static final int QUALIFICATION_SLA_HOURS = 2;

    /**
     * 工具类：禁止实例化。
     */
    private NfrCert() {
        throw new AssertionError("NfrCert 是常量类，不可实例化");
    }
}
