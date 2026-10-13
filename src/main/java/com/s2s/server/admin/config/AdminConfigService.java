package com.s2s.server.admin.config;

import com.s2s.server.admin.dto.MatchConfigResponse;
import com.s2s.server.admin.dto.MatchConfigUpdateRequest;
import com.s2s.server.admin.dto.SwitchConfigResponse;
import com.s2s.server.admin.dto.SwitchConfigUpdateRequest;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.NfrMatch;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.Locale;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 运营后台配置类服务（[153] B2-5）：撮合权重 + AB 开关（PRD §9.10.1 ③）、
 * 模型/性能降级开关（PRD §9.10.1 ⑦）。
 *
 * <p><b>RBAC</b>：两页均属「算法运营」职责（PRD §9.10.1 角色表）——算法运营与超级管理员可操作，
 * 其余角色一律 {@code 40305}（越权统一同码）。</p>
 *
 * <p><b>审计</b>：权重与开关变更属 PRD §9.10.1「必留操作」，写入与配置落库<b>同事务</b>
 * （{@link AuditLogWriter} 不加 {@code @Transactional}，加入本方法事务）。配置无自然主键 ID，
 * 审计 {@code target_type=system_config}、{@code target_id=0} 为哨兵（承接「无对象 ID」场景）。</p>
 *
 * <p><b>默认值</b>：配置键缺失时回退到 {@link NfrMatch} 的 PRD §6.11 唯一口径（0.40/0.40/0.20）
 * —— 使「未配置」与「配置为默认值」行为一致，不因后台未初始化而改变排序口径。</p>
 */
@Service
public class AdminConfigService {

    /** 审计动作：撮合权重/AB 配置变更。 */
    static final String ACTION_MATCH_CONFIG = "match.config.update";

    /** 审计动作：降级开关变更。 */
    static final String ACTION_SWITCH_CONFIG = "switch.config.update";

    /** 审计目标类型：系统配置（无自然 ID，target_id 用 0 哨兵）。 */
    static final String TARGET_SYSTEM_CONFIG = "system_config";

    /** 无自然主键场景的 target_id 哨兵值。 */
    static final long NO_TARGET_ID = 0L;

    /** 权重和与 1 的允许误差（浮点累加）。 */
    private static final double WEIGHT_SUM_TOLERANCE = 1e-6;

    /** 配置读写服务（common 域）。 */
    private final SystemConfigService systemConfigService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台配置服务。
     *
     * @param systemConfigService 系统配置读写服务
     * @param auditLogWriter      审计写入器
     */
    public AdminConfigService(SystemConfigService systemConfigService,
            AuditLogWriter auditLogWriter) {
        this.systemConfigService = systemConfigService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 读取撮合权重配置（缺失回退 PRD §6.11 默认口径）。
     *
     * @param callerRole 调用者角色
     * @return {@link MatchConfigResponse} 权重 + GBDT 开关 + 灰度比例
     * @throws BizException 非算法运营/超管 → 40305
     */
    public MatchConfigResponse getMatchConfig(OperatorRole callerRole) {
        requireAlgoOrSuper(callerRole);
        return new MatchConfigResponse(
                readDouble(AdminConfigKeys.MATCH_WEIGHT_TIME, NfrMatch.COMPOSITE_WEIGHT_TIME),
                readDouble(AdminConfigKeys.MATCH_WEIGHT_DISTANCE, NfrMatch.COMPOSITE_WEIGHT_DISTANCE),
                readDouble(AdminConfigKeys.MATCH_WEIGHT_COMPLETENESS,
                        NfrMatch.COMPOSITE_WEIGHT_COMPLETENESS),
                systemConfigService.isOn(AdminConfigKeys.MATCH_GBDT_ENABLED),
                (int) readDouble(AdminConfigKeys.MATCH_GRAY_RATIO, 0));
    }

    /**
     * 更新撮合权重配置（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参（三项权重 + GBDT 开关 + 灰度）
     * @throws BizException 非算法运营/超管 → 40305；权重和 ≠ 1 → 40001
     */
    @Transactional
    public void updateMatchConfig(OperatorRole callerRole, Long adminId,
            MatchConfigUpdateRequest req) {
        requireAlgoOrSuper(callerRole);
        double sum = req.weightTime() + req.weightDistance() + req.weightCompleteness();
        if (Math.abs(sum - 1.0) > WEIGHT_SUM_TOLERANCE) {
            // PRD §6.11 三权重为归一化权重，和必须为 1（否则「加权和」不再是凸组合）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        write(AdminConfigKeys.MATCH_WEIGHT_TIME, String.valueOf(req.weightTime()));
        write(AdminConfigKeys.MATCH_WEIGHT_DISTANCE, String.valueOf(req.weightDistance()));
        write(AdminConfigKeys.MATCH_WEIGHT_COMPLETENESS, String.valueOf(req.weightCompleteness()));
        write(AdminConfigKeys.MATCH_GBDT_ENABLED, onOff(req.gbdtEnabled()));
        write(AdminConfigKeys.MATCH_GRAY_RATIO, String.valueOf(req.grayRatio()));

        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_MATCH_CONFIG,
                TARGET_SYSTEM_CONFIG, NO_TARGET_ID, null,
                String.format(Locale.ROOT,
                        "{\"time\":%s,\"distance\":%s,\"completeness\":%s,\"gbdt\":%s,\"gray\":%d}",
                        req.weightTime(), req.weightDistance(), req.weightCompleteness(),
                        req.gbdtEnabled(), req.grayRatio()),
                null));
    }

    /**
     * 读取降级开关。
     *
     * @param callerRole 调用者角色
     * @return {@link SwitchConfigResponse} 模型/性能降级开关
     * @throws BizException 非算法运营/超管 → 40305
     */
    public SwitchConfigResponse getSwitches(OperatorRole callerRole) {
        requireAlgoOrSuper(callerRole);
        return new SwitchConfigResponse(
                systemConfigService.isOn(AdminConfigKeys.MODEL_DOWNGRADE_ENABLED),
                systemConfigService.isOn(AdminConfigKeys.PERF_DOWNGRADE_ENABLED));
    }

    /**
     * 更新降级开关（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参
     * @throws BizException 非算法运营/超管 → 40305
     */
    @Transactional
    public void updateSwitches(OperatorRole callerRole, Long adminId,
            SwitchConfigUpdateRequest req) {
        requireAlgoOrSuper(callerRole);
        write(AdminConfigKeys.MODEL_DOWNGRADE_ENABLED, onOff(req.modelDowngradeEnabled()));
        write(AdminConfigKeys.PERF_DOWNGRADE_ENABLED, onOff(req.perfDowngradeEnabled()));

        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_SWITCH_CONFIG,
                TARGET_SYSTEM_CONFIG, NO_TARGET_ID, null,
                String.format(Locale.ROOT, "{\"modelDowngrade\":%s,\"perfDowngrade\":%s}",
                        req.modelDowngradeEnabled(), req.perfDowngradeEnabled()),
                null));
    }

    /**
     * RBAC：算法运营或超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireAlgoOrSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.ALGO && callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 写一个配置键。
     *
     * @param key   配置键
     * @param value 配置值
     */
    private void write(String key, String value) {
        systemConfigService.putValue(key, value, "运营治理后台配置（[153] B2-5）");
    }

    /**
     * 读数值配置，缺失回退默认值。
     *
     * @param key          配置键
     * @param defaultValue 默认值
     * @return double 配置值；缺失/非法时返回默认值
     */
    private double readDouble(String key, double defaultValue) {
        String raw = systemConfigService.getValue(key);
        if (raw == null || raw.isBlank()) {
            return defaultValue;
        }
        try {
            return Double.parseDouble(raw);
        } catch (NumberFormatException exception) {
            return defaultValue;
        }
    }

    /**
     * 布尔 → on/off 落库值。
     *
     * @param enabled 布尔值
     * @return {@link String} {@code on} 或 {@code off}
     */
    private String onOff(boolean enabled) {
        return enabled ? AdminConfigKeys.VALUE_ON : AdminConfigKeys.VALUE_OFF;
    }
}
