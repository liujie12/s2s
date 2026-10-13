package com.s2s.server.contact;

import java.util.Map;

/**
 * 举报分级风险分计算与阈值判定（[153] B2-5 ④；PRD §9.10.3「举报分级响应引擎」）。
 *
 * <p>§9.10.3 是「被举报后是否下架」的**唯一判定规则**（§3.7/§7.8/§9.6 均引用本节，
 * 不另设阈值）。本类只承载「原因分 × 举报方权重」这一步纯计算与阈值比较，
 * 不改库、不判状态 —— 落库与下架动作由 {@link ContactService} 调 post 域执行。</p>
 *
 * <p>口径（§9.10.3 逐字）：
 * <ul>
 *   <li>原因 5 类基础风险分：诈骗收费 50 / 不实信息 20 / 违规类目 20 / 骚扰 10 / 其他 5；</li>
 *   <li>举报方权重：普通实名 ×1，企业认证 ×1.5；</li>
 *   <li>触发条件：单条发布累计风险分 ≥ {@link #AUTO_OFFLINE_THRESHOLD} → 自动下架 + 人工复核。</li>
 * </ul>
 * 值域常量落本类（阈值只引用常量名，禁业务代码写死数字）。</p>
 */
public final class ReportRiskScore {

    /**
     * 工具类：禁止实例化。
     */
    private ReportRiskScore() {
        throw new AssertionError("ReportRiskScore 是常量/工具类，不可实例化");
    }

    /** 自动下架阈值（单条发布累计风险分 ≥ 此值 → 自动下架 + 人工复核）。PRD §9.10.3。 */
    public static final int AUTO_OFFLINE_THRESHOLD = 60;

    /** 举报方权重基准（普通实名用户 ×1；权重以「千分比整数」表达以避免浮点）。 */
    static final int WEIGHT_NORMAL_MILLIS = 1000;

    /** 企业认证用户权重 ×1.5（= 1500‰）。 */
    static final int WEIGHT_ENTERPRISE_MILLIS = 1500;

    /** 原因基础风险分表（键 = {@code report.reason} 枚举值，与 DDL 严格一致）。 */
    private static final Map<String, Integer> BASE_SCORE = Map.of(
            "fraud", 50,
            "false_info", 20,
            "wrong_category", 20,
            "harassment", 10,
            "other", 5);

    /**
     * 计算单次举报的风险分（基础分 × 举报方权重，向下取整）。
     *
     * <p>用整数千分比而非浮点：风险分累计要与阈值 60 做整数比较，
     * 浮点会引入 59.999… 这类边界抖动（一个举报就可能翻转是否下架）。</p>
     *
     * @param reason         举报原因（契约枚举：fraud/false_info/wrong_category/harassment/other）
     * @param enterpriseUser 举报方是否企业认证用户（true ×1.5，false ×1）
     * @return int 本次举报贡献的风险分；原因非法时按 {@code other}（5）计
     */
    public static int of(String reason, boolean enterpriseUser) {
        // reason 为 null 时不能直接喂 Map.of(...) 的 getOrDefault（不可变 Map 不接受 null 键，
        // 会抛 NPE）；先归一到 other 再查表。
        String key = reason == null ? "other" : reason;
        int base = BASE_SCORE.getOrDefault(key, BASE_SCORE.get("other"));
        int weightMillis = enterpriseUser ? WEIGHT_ENTERPRISE_MILLIS : WEIGHT_NORMAL_MILLIS;
        return base * weightMillis / 1000;
    }

    /**
     * 判断累计风险分是否触发自动下架。
     *
     * @param cumulativeScore 该条发布的累计风险分
     * @return boolean；{@code true} 表示 ≥ 阈值，应自动下架并进人工复核
     */
    public static boolean shouldAutoOffline(int cumulativeScore) {
        return cumulativeScore >= AUTO_OFFLINE_THRESHOLD;
    }
}
