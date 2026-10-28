package com.s2s.server.cert;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.ai.AiProvider;
import com.s2s.server.ai.dto.CertProfileGuess;
import com.s2s.server.auth.UserService;
import com.s2s.server.cert.dto.CertOcrResult;
import com.s2s.server.cert.dto.CertStatusResponse;
import com.s2s.server.cert.dto.QualificationSubmitRequest;
import com.s2s.server.cert.dto.QualificationSubmitResult;
import com.s2s.server.cert.dto.QualificationUpdateRequest;
import com.s2s.server.cert.dto.RealnameSubmitRequest;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.cert.mapper.CertMapper;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.Pepper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.MediaService;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.temporal.ChronoUnit;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link CertService} 测试。
 *
 * <p>覆盖实名认证全链路、资质提交即生效（approved/expired/长期有效）、有效期缺失校验、
 * 档案列表、证照图抽取（成功/上游不可用）、编辑续期回 approved、删除清理证照原件。</p>
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
    private MediaService mediaService;
    private AiProvider aiProvider;
    private CertService service;

    @BeforeEach
    void setUp() {
        userService = mock(UserService.class);
        certMapper = mock(CertMapper.class);
        realnameProvider = mock(RealnameProvider.class);
        cryptoFacade = mock(CryptoFacade.class);
        auditLogWriter = mock(AuditLogWriter.class);
        certFailureRecorder = mock(CertFailureRecorder.class);
        mediaService = mock(MediaService.class);
        aiProvider = mock(AiProvider.class);
        service = new CertService(userService, certMapper, realnameProvider, cryptoFacade,
                PEPPERS, auditLogWriter, certFailureRecorder, mediaService, aiProvider);
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

    /**
     * 构造资质提交请求（有到期日）。
     *
     * @param expireAt 有效期至（UTC）
     * @return {@link QualificationSubmitRequest} 资质提交请求
     */
    private QualificationSubmitRequest qualification(Instant expireAt) {
        return new QualificationSubmitRequest("personal_qualification", List.of("m1"),
                "家政服务资质", "ocr", "dated", expireAt);
    }

    /**
     * 构造一条已存在的资质记录。
     *
     * @param status    状态
     * @param expireAt  到期时间（可空）
     * @param expireType 有效期类型
     * @return {@link CertEntity} 资质记录
     */
    private CertEntity existingCert(String status, LocalDateTime expireAt, String expireType) {
        CertEntity entity = new CertEntity();
        entity.setId(9L);
        entity.setUserId(1L);
        entity.setCertType("personal_qualification");
        entity.setStatus(status);
        entity.setExpireType(expireType);
        entity.setExpireAt(expireAt);
        entity.setOcrImageRef("m1");
        return entity;
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
        assertThatThrownBy(() -> service.submitQualification(1L,
                qualification(Instant.now().plus(30, ChronoUnit.DAYS))))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.QUALIFICATION_NEEDED);
    }

    @Test
    void 提交资质即approved并落证名与有效期() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        QualificationSubmitResult result = service.submitQualification(1L,
                qualification(Instant.now().plus(30, ChronoUnit.DAYS)));

        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).insert(captor.capture());
        CertEntity saved = captor.getValue();
        assertThat(result.status()).isEqualTo("approved");
        assertThat(saved.getStatus()).isEqualTo("approved");
        assertThat(saved.getCertName()).isEqualTo("家政服务资质");
        assertThat(saved.getNameSource()).isEqualTo("ocr");
        assertThat(saved.getExpireType()).isEqualTo("dated");
        assertThat(saved.getExpireAt()).isNotNull();
        assertThat(saved.getApprovedAt()).isNotNull();
        verify(mediaService).ensureOwned(1L, "m1");
    }

    @Test
    void 提交已过有效期直接expired() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        QualificationSubmitResult result = service.submitQualification(1L,
                qualification(Instant.now().minus(1, ChronoUnit.DAYS)));
        assertThat(result.status()).isEqualTo(CertService.CERT_STATUS_EXPIRED);
    }

    @Test
    void 长期有效不写到期时间() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        QualificationSubmitRequest request = new QualificationSubmitRequest(
                "personal_qualification", List.of("m1"), "养老护理员证", "manual", "permanent", null);
        service.submitQualification(1L, request);

        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).insert(captor.capture());
        assertThat(captor.getValue().getStatus()).isEqualTo("approved");
        assertThat(captor.getValue().getExpireAt()).isNull();
    }

    @Test
    void 有到期日但缺有效期回40001() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        QualificationSubmitRequest request = new QualificationSubmitRequest(
                "personal_qualification", List.of("m1"), "证", "manual", "dated", null);
        assertThatThrownBy(() -> service.submitQualification(1L, request))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    @Test
    void 个人实名不能作为资质提交() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        QualificationSubmitRequest request = new QualificationSubmitRequest(
                "personal_realname", List.of("m1"), null, null, "permanent", null);
        assertThatThrownBy(() -> service.submitQualification(1L, request))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    @Test
    void 查询认证状态返回实名与资质条目() {
        when(userService.realnameStatusOf(1L)).thenReturn(CertService.REALNAME_STATUS_PASSED);
        CertEntity row = existingCert("approved", LocalDateTime.now().plusDays(1), "dated");
        row.setOcrImageRef(null);
        when(certMapper.selectList(any())).thenReturn(List.of(row));

        CertStatusResponse status = service.getCertStatus(1L);
        assertThat(status.realname().status()).isEqualTo(CertService.REALNAME_STATUS_PASSED);
        assertThat(status.qualifications()).hasSize(1);
        assertThat(status.qualifications().get(0).certId()).isEqualTo(9L);
    }

    @Test
    void 抽取成功返回证名与有效期() {
        Instant expire = Instant.now().plus(30, ChronoUnit.DAYS);
        when(mediaService.signAiReadAccess(1L, "m1"))
                .thenReturn(new MediaService.AiMediaAccess("https://signed", "image/jpeg"));
        when(aiProvider.extractCertProfile(eq(1L), eq("https://signed"), eq("image/jpeg")))
                .thenReturn(new CertProfileGuess("家政服务资质", expire));

        CertOcrResult result = service.extractCertProfile(1L, "m1");
        assertThat(result.certName()).isEqualTo("家政服务资质");
        assertThat(result.expireAt()).isEqualTo(expire);
    }

    @Test
    void 抽取读不出时返回空值不报错() {
        when(mediaService.signAiReadAccess(1L, "m1"))
                .thenReturn(new MediaService.AiMediaAccess("https://signed", "image/jpeg"));
        when(aiProvider.extractCertProfile(anyLong(), any(), any()))
                .thenReturn(CertProfileGuess.empty());

        CertOcrResult result = service.extractCertProfile(1L, "m1");
        assertThat(result.certName()).isNull();
        assertThat(result.expireAt()).isNull();
    }

    @Test
    void 抽取上游不可用回50301() {
        when(mediaService.signAiReadAccess(1L, "m1"))
                .thenReturn(new MediaService.AiMediaAccess("https://signed", "image/jpeg"));
        when(aiProvider.extractCertProfile(anyLong(), any(), any()))
                .thenThrow(new IllegalStateException("upstream down"));

        assertThatThrownBy(() -> service.extractCertProfile(1L, "m1"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.AI_UNAVAILABLE);
    }

    @Test
    void 编辑续期把expired改回approved() {
        CertEntity row = existingCert(CertService.CERT_STATUS_EXPIRED,
                LocalDateTime.now().minusDays(10), "dated");
        when(certMapper.selectById(9L)).thenReturn(row);

        QualificationSubmitResult result = service.updateQualification(1L, 9L,
                new QualificationUpdateRequest(null, null, null, "dated",
                        Instant.now().plus(60, ChronoUnit.DAYS)));

        assertThat(result.status()).isEqualTo("approved");
        verify(certMapper).update(eq(null), any());
    }

    @Test
    void 编辑空载荷回40001() {
        when(certMapper.selectById(9L))
                .thenReturn(existingCert("approved", LocalDateTime.now().plusDays(1), "dated"));
        assertThatThrownBy(() -> service.updateQualification(1L, 9L,
                new QualificationUpdateRequest(null, null, null, null, null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    @Test
    void 删除资质清理证照并删记录() {
        when(certMapper.selectById(9L))
                .thenReturn(existingCert("approved", LocalDateTime.now().plusDays(1), "dated"));

        service.deleteQualification(1L, 9L);

        verify(mediaService).deleteOwnedMedia(1L, "m1");
        verify(certMapper).deleteById(9L);
    }

    @Test
    void 非本人资质编辑与删除回40001() {
        CertEntity row = existingCert("approved", LocalDateTime.now().plusDays(1), "dated");
        row.setUserId(2L);
        when(certMapper.selectById(9L)).thenReturn(row);

        assertThatThrownBy(() -> service.deleteQualification(1L, 9L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(certMapper, never()).deleteById(anyLong());
    }
}
