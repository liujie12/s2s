package com.s2s.server.common.retention;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * 数据保留策略注册表（Batch1 R17；《数据库设计文档》§5 + PRD §13.4 + DevSecOps 接入方案 §6）。
 *
 * <p><b>存在理由</b>：《数据库设计文档》§5 明写「每一行都必须在架构 §8 定时任务表里有对应的
 * 执行者，否则保留期只是文档承诺而不是系统行为」（架构 §8 同义）。本类把这 9 条保留策略键
 * 从文档搬进代码，使「哪条策略由谁执行」成为可被门禁比对的实体——{@link #keys()} 与
 * PRD §13.4 表格的「保留策略键」列由 {@code RetentionRuleCoverageTest} 断言逐值相等，
 * 任一侧改动而另一侧未跟进即构建失败。</p>
 *
 * <p><b>为什么值不是「Spring bean 名」</b>：9 条策略中只有 4 条的执行者是定时任务
 * （清理类），另有 4 条的执行者是<b>域内既有代码路径</b>（如 EXIF 剥离在上传链路、
 * 位置不采集在写入前断言）、1 条为「仅状态流转、无清理任务」，还有 2 条属 Batch2。
 * 若把值强制为 bean 名，就得为不存在的东西编造 bean；故值统一为「执行者说明」文本
 * （任务类名 / 域内方法 / Batch2 标注），并允许 {@link #PENDING} 标注未落地项。</p>
 *
 * <p><b>当前 9 条的落地状态</b>（2026-09-29 [129] 落地时）：</p>
 * <ul>
 *   <li>已实现：{@code favorite_deleted_30d}（收藏记录清理任务）、{@code deactivate_7d}
 *       （注销清理任务）、{@code audit_log_180d}（审计日志清理任务）；</li>
 *   <li>非任务型执行者（既有代码路径，本轮不改）：{@code exif_strip}、{@code location_no_collect}、
 *       {@code post_archived_keep}；</li>
 *   <li>Batch2 随域交付：{@code ocr_image_7d}、{@code publish_memory_180d}；</li>
 *   <li><b>待裁定</b>：{@code transit_log_30d} —— 存储载体设计文档未定义，清理动作未实现，
 *       见说明文档 §2.9（用户 2026-09-29 裁定「登记缺口 + 只注册保留键」）。</li>
 * </ul>
 */
public final class RetentionRuleRegistry {

    /** 未落地项的标注文案前缀：出现在值里即表示该条尚无执行实现（门禁据此可统计）。 */
    public static final String PENDING = "待落地：";

    /**
     * 保留策略键 → 执行者说明（9 条，逐行对回《数据库设计文档》§5 矩阵）。
     *
     * <p>用 {@link LinkedHashMap} 保持与文档表格同序，便于人工逐行核对。</p>
     */
    private static final Map<String, String> RULES = new LinkedHashMap<>();

    static {
        RULES.put("ocr_image_7d",
                PENDING + "Batch2 随 cert 域交付（删 OSS + 清 cert.ocr_image_ref）");
        RULES.put("transit_log_30d",
                PENDING + "存储载体设计文档未定义（PRD §7.4.2 无载体、可观测 §2 三类数据中无此对象），"
                        + "见说明文档 §2.9 待裁定项");
        RULES.put("favorite_deleted_30d", "task.FavoriteCleanupTask（软删满 30 天物理删除）");
        RULES.put("publish_memory_180d", PENDING + "Batch2 随发布记忆功能交付");
        RULES.put("deactivate_7d",
                "task.DeactivateCleanupTask（按 user_id 删全部身份行 + 清实名结果与手机号掩码）");
        RULES.put("post_archived_keep", "无清理任务：仅 status 流转归档，不物理删除（post 域状态机）");
        RULES.put("audit_log_180d", "task.AuditLogCleanupTask（删除超过 180 天的审计行）");
        RULES.put("exif_strip", "post 域媒体上传链路（上传时服务端强制剥离 EXIF，非定时任务）");
        RULES.put("location_no_collect", "post 域写入前断言（只存发布点经纬度，不采集轨迹）");
    }

    /**
     * 私有构造器：注册表为静态数据 + 纯查询，无实例状态。
     */
    private RetentionRuleRegistry() {
    }

    /**
     * 取全部保留策略键（与 PRD §13.4 表格逐值比对的比对面）。
     *
     * @return {@link Set} 9 条保留策略键（不可变视图）
     */
    public static Set<String> keys() {
        return Set.copyOf(RULES.keySet());
    }

    /**
     * 取「保留策略键 → 执行者说明」的全部映射（保持文档表格顺序）。
     *
     * @return {@link Map} 键 → 执行者说明（不可变视图）
     */
    public static Map<String, String> rules() {
        return Map.copyOf(RULES);
    }

    /**
     * 取尚未落地的保留策略键（值以 {@link #PENDING} 开头者）。
     *
     * @return {@link Set} 待落地键集合；全部落地时为空集
     */
    public static Set<String> pendingKeys() {
        return RULES.entrySet().stream()
                .filter(entry -> entry.getValue().startsWith(PENDING))
                .map(Map.Entry::getKey)
                .collect(Collectors.toUnmodifiableSet());
    }
}
