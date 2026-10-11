package com.s2s.server.cert;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.UserService;
import com.s2s.server.cert.dto.CertStatusResponse;
import com.s2s.server.cert.dto.QualificationSubmitRequest;
import com.s2s.server.cert.dto.RealnameSubmitRequest;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.cert.mapper.CertMapper;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.Pepper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link CertService} 实名认证服务测试（[149]；由空壳测试转真）。
 *
 * <p>覆盖：未实名状态兜底、协议未勾选 40002、已实名幂等、核验失败 40001 + 记失败、
 * 核验通过写 user/cert/审计、未实名提交资质 40302、认证状态查询。</p>
 */
class CertServiceTest {

    /** 测试 pepper（32 字节 hex，供 BlindIndex 真实执行）。 */
    private static final List<Pepper> PEPPERS = List.of(
            Pepper.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));

    private UserService userService;
    private CertMapper certMapper;
    private RealnameProvider realnameProvider;
    private CryptoFacade cryptoFacade;
    private AuditLogWriter auditLogWriter;
    private CertFailureRecorder certFailureRecorder;
    private CertService service;

    @BeforeEach
    void setUp() {
        userService = mock(UserService.class);
        certMapper = mock(CertMapper.class);
        realnameProvider = mock(RealnameProvider.class);
        cryptoFacade = mock(CryptoFacade.class);
        auditLogWriter = mock(AuditLogWriter.class);
        certFailureRecorder = mock(CertFailureRecorder.class);
        service = new CertService(userService, certMapper, realnameProvider, cryptoFacade,
                PEPPERS, auditLogWriter, certFailureRecorder);
    }

    /**
     * 构造实名提交请求（身份证号尾号 0000 供 dry-run mock 通过判定）。
     *
     * @param agreed 是否已勾选协议
     * @return {@link RealnameSubmitRequest} 实名提交请求
     */
    private RealnameSubmitRequest request(boolean agreed) {
        return new RealnameSubmitRequest("张三", "110101199003070000", agreed);
    }

    @Test
    void 用户不存在实名状态返回none() {
        when(userService.realnameStatusOf(1L)).thenReturn(null);
        assertThat(service.getRealnameStatus(1L)).isEqualTo(CertService.REALNAME_STATUS_NONE);
    }

    @Test
    void 协议未勾选回40002() {
        assertThatThrownBy(() -> service.submitRealname(1L, request(false)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.AGREEMENT_REQUIRED);
    }

    @Test
    void 已实名幂等返回不调供应商() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        assertThat(service.submitRealname(1L, request(true)).status())
                .isEqualTo(CertService.REALNAME_STATUS_PASSED);
        verify(realnameProvider, never()).verify(any(), any());
    }

    @Test
    void 核验不通过回40001并记失败() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_NONE);
        when(realnameProvider.verify(any(), any())).thenReturn(false);
        assertThatThrownBy(() -> service.submitRealname(1L, request(true)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(certFailureRecorder).recordFailure(eq(1L));
    }

    @Test
    void 锁定期内回40001且不调供应商() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_NONE);
        when(certFailureRecorder.isLocked(1L)).thenReturn(true);
        assertThatThrownBy(() -> service.submitRealname(1L, request(true)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(realnameProvider, never()).verify(any(), any());
    }

    @Test
    void 核验通过写user与cert与审计() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_NONE);
        when(realnameProvider.verify(any(), any())).thenReturn(true);
        when(cryptoFacade.encrypt(any(), any()))
                .thenReturn(new CryptoFacade.EncryptResult(1, new byte[] {1, 2, 3}));
        assertThat(service.submitRealname(1L, request(true)).status())
                .isEqualTo(CertService.REALNAME_STATUS_PASSED);
        verify(userService).applyRealnameResult(eq(1L), eq(CertService.REALNAME_STATUS_PASSED),
                any(), any(), any(), eq(1));
        verify(certMapper).insert(any(CertEntity.class));
        verify(auditLogWriter).write(any());
    }

    @Test
    void 未实名提交资质回40302() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_NONE);
        QualificationSubmitRequest request =
                new QualificationSubmitRequest("enterprise", List.of("m1"));
        assertThatThrownBy(() -> service.submitQualification(1L, request))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.QUALIFICATION_NEEDED);
    }

    @Test
    void 查询认证状态返回状态与空资质列表() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_NONE);
        CertStatusResponse status = service.getCertStatus(1L);
        assertThat(status.realname().status()).isEqualTo(CertService.REALNAME_STATUS_NONE);
        assertThat(status.qualifications()).isEmpty();
    }
}
