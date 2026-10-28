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
 * {@link PostCredentialAssembler} 测试（V22 帖级凭证声明；V23 简化后）。
 *
 * <p>覆盖：无声明不渲染、当前有效才渲染（valid）、撤销/删除整块不渲染、
 * 写入与替换只落证名快照。</p>
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
     * 造一条声明记录（V23 起只有证名快照）。
     *
     * @return {@link PostCertDeclarationEntity} 声明记录
     */
    private PostCertDeclarationEntity declaration() {
        PostCertDeclarationEntity entity = new PostCertDeclarationEntity();
        entity.setId(1L);
        entity.setPostId(100L);
        entity.setCertId(9L);
        entity.setCertNameSnapshot("家政服务资质");
        entity.setDeclaredAt(LocalDateTime.now());
        return entity;
    }

    /**
     * 造资质当前快照。
     *
     * @param status 当前状态
     * @return {@link CertSnapshot} 快照
     */
    private CertSnapshot cert(String status) {
        return new CertSnapshot(9L, "家政服务资质", status);
    }

    @Test
    void 无声明返回null() {
        when(declarationMapper.selectOne(any())).thenReturn(null);
        assertThat(assembler.of(100L)).isNull();
    }

    @Test
    void 凭证当前有效state为valid() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration());
        when(certService.findSnapshot(9L)).thenReturn(cert("approved"));

        PostCredential credential = assembler.of(100L);
        assertThat(credential).isNotNull();
        assertThat(credential.state()).isEqualTo("valid");
        assertThat(credential.certName()).isEqualTo("家政服务资质");
    }

    @Test
    void 凭证被删除整块不渲染() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration());
        when(certService.findSnapshot(9L)).thenReturn(null);
        assertThat(assembler.of(100L)).isNull();
    }

    @Test
    void 凭证被撤销整块不渲染() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration());
        when(certService.findSnapshot(9L)).thenReturn(cert("rejected"));
        assertThat(assembler.of(100L)).isNull();
    }

    @Test
    void 首次挂载只写证名快照() {
        when(declarationMapper.selectOne(any())).thenReturn(null);

        assembler.upsert(100L, cert("approved"));

        ArgumentCaptor<PostCertDeclarationEntity> captor =
                ArgumentCaptor.forClass(PostCertDeclarationEntity.class);
        verify(declarationMapper).insert(captor.capture());
        assertThat(captor.getValue().getPostId()).isEqualTo(100L);
        assertThat(captor.getValue().getCertId()).isEqualTo(9L);
        assertThat(captor.getValue().getCertNameSnapshot()).isEqualTo("家政服务资质");
    }

    @Test
    void 已有声明时按替换更新而非新增() {
        when(declarationMapper.selectOne(any())).thenReturn(declaration());

        assembler.upsert(100L, cert("approved"));

        verify(declarationMapper).update(any(), any());
        verify(declarationMapper, org.mockito.Mockito.never())
                .insert(org.mockito.ArgumentMatchers.any(PostCertDeclarationEntity.class));
    }
}
