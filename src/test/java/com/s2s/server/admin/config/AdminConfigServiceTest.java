package com.s2s.server.admin.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.MatchConfigResponse;
import com.s2s.server.admin.dto.MatchConfigUpdateRequest;
import com.s2s.server.admin.dto.SwitchConfigResponse;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.NfrMatch;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminConfigService} 单元测试（[153] B2-5 ③⑦ 两页）。
 *
 * <p>守三件事：① RBAC（仅算法运营/超管，其余 40305 且不触达配置读写）；
 * ② 权重和必须为 1（否则 40001）；③ 配置缺失回退 PRD §6.11 默认口径。</p>
 */
class AdminConfigServiceTest {

    /** 系统配置服务（mock）。 */
    private SystemConfigService systemConfigService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminConfigService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        systemConfigService = mock(SystemConfigService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminConfigService(systemConfigService, auditLogWriter);
    }

    /**
     * 配置缺失 → 权重回退 PRD §6.11 默认 0.40/0.40/0.20。
     *
     * @return void；断言失败即未初始化后台会改变排序口径
     */
    @Test
    void getMatchConfigFallsBackToPrdDefaults() {
        when(systemConfigService.getValue(anyString())).thenReturn(null);

        MatchConfigResponse response = service.getMatchConfig(OperatorRole.ALGO);

        assertThat(response.weightTime()).isEqualTo(NfrMatch.COMPOSITE_WEIGHT_TIME);
        assertThat(response.weightDistance()).isEqualTo(NfrMatch.COMPOSITE_WEIGHT_DISTANCE);
        assertThat(response.weightCompleteness()).isEqualTo(NfrMatch.COMPOSITE_WEIGHT_COMPLETENESS);
        assertThat(response.gbdtEnabled()).isFalse();
        assertThat(response.grayRatio()).isZero();
    }

    /**
     * 非算法运营/超管 → 40305，且不读写配置。
     *
     * @return void；断言失败即越权可改权重/开关
     */
    @Test
    void nonAlgoRoleDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.OPERATOR,
                OperatorRole.USER}) {
            assertThatThrownBy(() -> service.getSwitches(role))
                    .as("角色 %s 不应可读配置", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(systemConfigService, never()).putValue(anyString(), anyString(), anyString());
    }

    /**
     * 权重和 ≠ 1 → 40001，且不落库不留痕。
     *
     * @return void；断言失败即非归一化权重可写入（凸组合被破坏）
     */
    @Test
    void weightSumNotOneRejected() {
        MatchConfigUpdateRequest bad = new MatchConfigUpdateRequest(0.5, 0.5, 0.5, false, 0);

        assertThatThrownBy(() -> service.updateMatchConfig(OperatorRole.ALGO, 1L, bad))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(systemConfigService, never()).putValue(anyString(), anyString(), anyString());
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * 权重和为 1 → 落库五个键 + 写审计（同事务）。
     *
     * @return void；断言失败即配置或留痕缺失
     */
    @Test
    void weightSumOneWritesConfigAndAudit() {
        MatchConfigUpdateRequest ok = new MatchConfigUpdateRequest(0.4, 0.4, 0.2, true, 10);

        service.updateMatchConfig(OperatorRole.ALGO, 7L, ok);

        verify(systemConfigService).putValue(eq(AdminConfigKeys.MATCH_WEIGHT_TIME), anyString(),
                anyString());
        verify(systemConfigService).putValue(eq(AdminConfigKeys.MATCH_GBDT_ENABLED), eq("on"),
                anyString());
        verify(systemConfigService).putValue(eq(AdminConfigKeys.MATCH_GRAY_RATIO), eq("10"),
                anyString());
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 超管可读开关；开关值 on → true。
     *
     * @return void
     */
    @Test
    void superAdminReadsSwitches() {
        when(systemConfigService.isOn(AdminConfigKeys.MODEL_DOWNGRADE_ENABLED)).thenReturn(true);
        when(systemConfigService.isOn(AdminConfigKeys.PERF_DOWNGRADE_ENABLED)).thenReturn(false);

        SwitchConfigResponse response = service.getSwitches(OperatorRole.SUPER_ADMIN);

        assertThat(response.modelDowngradeEnabled()).isTrue();
        assertThat(response.perfDowngradeEnabled()).isFalse();
    }
}
