package com.s2s.server.cert;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.cert.mapper.CertMapper;
import com.s2s.server.common.constants.NfrCert;
import java.time.LocalDateTime;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link CertFailureRecorder} 核验失败计数与锁定记录器测试（[149] 评审 P0/P1 修复）。
 *
 * <p>覆盖：首次失败 insert、未达阈值累加、达阈值写锁定、锁过期重新计数、锁定判定。
 * 事务边界（{@code REQUIRES_NEW} 独立提交）由 Spring 代理保证，本测试聚焦计数语义。</p>
 */
class CertFailureRecorderTest {

    private CertMapper certMapper;
    private CertFailureRecorder recorder;

    @BeforeEach
    void setUp() {
        certMapper = mock(CertMapper.class);
        recorder = new CertFailureRecorder(certMapper);
    }

    /**
     * 构造一条 mock 实名 cert 记录。
     *
     * @param failCount 已有失败次数
     * @param lockUntil 锁定截止时间（null 表示未锁定）
     * @return {@link CertEntity} mock 记录
     */
    private CertEntity record(int failCount, LocalDateTime lockUntil) {
        CertEntity entity = new CertEntity();
        entity.setId(1L);
        entity.setUserId(1L);
        entity.setCertType(CertService.CERT_TYPE_PERSONAL_REALNAME);
        entity.setStatus(CertService.CERT_STATUS_PENDING);
        entity.setFailCount(failCount);
        entity.setLockUntil(lockUntil);
        return entity;
    }

    @Test
    void 无记录首次失败插入failCount1() {
        when(certMapper.selectOne(any())).thenReturn(null);
        recorder.recordFailure(1L);
        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).insert(captor.capture());
        assertThat(captor.getValue().getFailCount()).isEqualTo(1);
        assertThat(captor.getValue().getLockUntil()).isNull();
    }

    @Test
    void 未达阈值累加() {
        when(certMapper.selectOne(any())).thenReturn(record(1, null));
        recorder.recordFailure(1L);
        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).updateById(captor.capture());
        assertThat(captor.getValue().getFailCount()).isEqualTo(2);
        assertThat(captor.getValue().getLockUntil()).isNull();
    }

    @Test
    void 达阈值写锁定() {
        when(certMapper.selectOne(any()))
                .thenReturn(record(NfrCert.REALNAME_FAIL_LOCK_THRESHOLD - 1, null));
        recorder.recordFailure(1L);
        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).updateById(captor.capture());
        assertThat(captor.getValue().getFailCount())
                .isEqualTo(NfrCert.REALNAME_FAIL_LOCK_THRESHOLD);
        assertThat(captor.getValue().getLockUntil()).isNotNull();
    }

    @Test
    void 锁过期后重新计数() {
        LocalDateTime expired = LocalDateTime.now().minusSeconds(1);
        when(certMapper.selectOne(any())).thenReturn(record(3, expired));
        recorder.recordFailure(1L);
        ArgumentCaptor<CertEntity> captor = ArgumentCaptor.forClass(CertEntity.class);
        verify(certMapper).updateById(captor.capture());
        assertThat(captor.getValue().getFailCount()).isEqualTo(1);
        assertThat(captor.getValue().getLockUntil()).isNull();
    }

    @Test
    void 锁定期内返回true() {
        LocalDateTime future = LocalDateTime.now().plusSeconds(100);
        when(certMapper.selectOne(any())).thenReturn(record(3, future));
        assertThat(recorder.isLocked(1L)).isTrue();
    }

    @Test
    void 锁过期返回false() {
        LocalDateTime expired = LocalDateTime.now().minusSeconds(1);
        when(certMapper.selectOne(any())).thenReturn(record(3, expired));
        assertThat(recorder.isLocked(1L)).isFalse();
    }
}
