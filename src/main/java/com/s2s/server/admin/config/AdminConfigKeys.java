package com.s2s.server.admin.config;

/**
 * 运营后台配置类页面的 {@code system_config} 键名常量（[153] B2-5）。
 *
 * <p>承载 PRD §9.10.1 ③「撮合权重配置 + AB 开关」与 ⑦「模型降级开关 + 性能降级开关」
 * 的配置键。键名在此唯一承载（禁业务代码拼字符串），值形态：
 * 权重用十进制字符串（如 {@code 0.40}）、开关用 {@code on}/{@code off}、灰度用整数百分比。</p>
 */
public final class AdminConfigKeys {

    /**
     * 工具类：禁止实例化。
     */
    private AdminConfigKeys() {
        throw new AssertionError("AdminConfigKeys 是常量类，不可实例化");
    }

    /** 撮合权重·时效（PRD §6.11，默认 0.40）。 */
    public static final String MATCH_WEIGHT_TIME = "match_weight_time";

    /** 撮合权重·距离（PRD §6.11，默认 0.40）。 */
    public static final String MATCH_WEIGHT_DISTANCE = "match_weight_distance";

    /** 撮合权重·完整度档（PRD §6.11，默认 0.20）。 */
    public static final String MATCH_WEIGHT_COMPLETENESS = "match_weight_completeness";

    /** GBDT override 开关（AB 灰度开关之一，on/off）。 */
    public static final String MATCH_GBDT_ENABLED = "match_gbdt_enabled";

    /** AB 灰度比例（整数百分比 0–100）。 */
    public static final String MATCH_GRAY_RATIO = "match_gray_ratio";

    /** 模型降级开关（PRD §6.12 冷启动降级，on/off）。 */
    public static final String MODEL_DOWNGRADE_ENABLED = "model_downgrade_enabled";

    /** 性能降级开关（PRD §6.10.1，on/off）。 */
    public static final String PERF_DOWNGRADE_ENABLED = "perf_downgrade_enabled";

    /** 开关配置的「开」值。 */
    public static final String VALUE_ON = "on";

    /** 开关配置的「关」值。 */
    public static final String VALUE_OFF = "off";
}
