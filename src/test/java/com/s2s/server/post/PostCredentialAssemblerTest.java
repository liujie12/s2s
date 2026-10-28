package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.post.dto.PostCredential;
import com.s2s.server.post.entity.PostCertDeclarationEntity;
import com.s2s.server.post.mapper.PostCertDeclarationMapper;
import java.time.LocalDateTime;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link PostCredentialAssembler} 测试（V22 帖级凭证声明）。
 *
 * <p>覆盖：无声明不渲染、脏数据不渲染、四种展示状态（valid/expired/revoked/deleted）、
 * 写入与替换（快照冻结）。</p>
 */
class PostCredentialAssemblerTest {

    private PostCertDeclarationMapper declarationMapper;
    private CertService certService;
    private PostCredentialAssembler assembler;

    @BeforeEach
    void setUp() {
        declarationMapper = mock(PostCertDeclarationMapper.class);
        certService = mock(CertService.class);
        assembler = new PostCredentialAssembler(declarationMapper, certService);
    }

    /**
     * 造一条声明记录。
     *
     * @param certStatusSnapshot 关联瞬间的凭证状态
     * @return {@link PostCertDeclarationEntity} 声明记录
     */
    private PostCertDeclarationEntity declaration(String certStatusSnapshot) {
        PostCertDeclarationEntity entity = new PostCertDeclarationEntity();
        entity.setId(1L);
        entity.setPostId(100L);
        entity.setCertId(9L);
        entity.setCertType("personal_qualification");
        entity.setCertNameSnapshot("家政服务资质");
        entity.setExpireAtSnapshot(LocalDateTime.now().plusDays(30));
        entity.setExpireTypeSnapshot("dated");
        entity.setCertStatusSnapshot(certStatusSnapshot);
        entity.setDeclaredAt(LocalDateTime.now());
        return entity;
    }

    /**
     * 造资质当前快照。
     *
     * @param status     当前状态
     * @param expireType 有效期类型
     * @param expireAt   到期时间（可空）
     * @return {@link CertSnapshot} 快照
     */
    private CertSnapshot cert(String status, String expireType, LocalDateTime expireAt) {
        return new CertSnapshot(9L, "personal_qualification", "家政服务资质", expireType, expireAt,
                status);
    }

    @Test
    void 无声明返回null() {
        when(declarationMapper.selectOne(any())).thenReturn(null);
        assertThat(assembler.of(100L)).isNull();
    }

    @Test
    void 关联瞬间已失效的脏数据整块不渲染() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("expired"));
        assertThat(assembler.of(100L)).isNull();
    }

    @Test
    void 凭证当前有效state为valid() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));
        when(certService.findSnapshot(9L))
                .thenReturn(cert("approved", "dated", LocalDateTime.now().plusDays(30)));

        PostCredential credential = assembler.of(100L);
        assertThat(credential).isNotNull();
        assertThat(credential.state()).isEqualTo("valid");
        assertThat(credential.certName()).isEqualTo("家政服务资质");
    }

    @Test
    void 凭证已到期state为expired() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));
        when(certService.findSnapshot(9L))
                .thenReturn(cert("expired", "dated", LocalDateTime.now().minusDays(1)));
        assertThat(assembler.of(100L).state()).isEqualTo("expired");
    }

    @Test
    void 凭证被删除state为deleted() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));
        when(certService.findSnapshot(9L)).thenReturn(null);
        assertThat(assembler.of(100L).state()).isEqualTo("deleted");
    }

    @Test
    void 凭证被驳回state为revoked() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));
        when(certService.findSnapshot(9L))
                .thenReturn(cert("rejected", "permanent", null));
        assertThat(assembler.of(100L).state()).isEqualTo("revoked");
    }

    @Test
    void 长期有效不受时间影响仍为valid() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));
        when(certService.findSnapshot(9L)).thenReturn(cert("approved", "permanent", null));
        assertThat(assembler.of(100L).state()).isEqualTo("valid");
    }

    @Test
    void 首次挂载写入快照() {
        when(declarationMapper.selectOne(any())).thenReturn(null);

        assembler.upsert(100L, cert("approved", "dated", LocalDateTime.now().plusDays(30)));

        ArgumentCaptor<PostCertDeclarationEntity> captor =
                ArgumentCaptor.forClass(PostCertDeclarationEntity.class);
        verify(declarationMapper).insert(captor.capture());
        assertThat(captor.getValue().getPostId()).isEqualTo(100L);
        assertThat(captor.getValue().getCertStatusSnapshot()).isEqualTo("approved");
        assertThat(captor.getValue().getCertNameSnapshot()).isEqualTo("家政服务资质");
    }

    @Test
    void 已有声明时按替换更新而非新增() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration("approved"));

        assembler.upsert(100L, cert("approved", "permanent", null));

        verify(declarationMapper).update(any(), any());
    }
}
