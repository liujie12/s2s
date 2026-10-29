package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.post.dto.PostCredential;
import com.s2s.server.post.entity.PostCertDeclarationEntity;
import com.s2s.server.post.mapper.PostCertDeclarationMapper;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link PostCredentialAssembler} 测试（V22 帖级凭证声明；V25 一帖多证）。
 *
 * <p>覆盖：无声明返回空列表、多证按挂载顺序输出、凭证删除/撤销时该项剔除、
 * 整体替换先清空再按入参写快照（去重）、空集合只清空不插入。</p>
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
     * @param id       声明记录 ID
     * @param certId   资质 ID
     * @param certName 证名快照
     * @return {@link PostCertDeclarationEntity} 声明记录
     */
    private PostCertDeclarationEntity declaration(long id, long certId, String certName) {
        PostCertDeclarationEntity entity = new PostCertDeclarationEntity();
        entity.setId(id);
        entity.setPostId(100L);
        entity.setCertId(certId);
        entity.setCertNameSnapshot(certName);
        entity.setDeclaredAt(LocalDateTime.now());
        return entity;
    }

    /**
     * 造资质当前快照。
     *
     * @param certId   资质 ID
     * @param certName 证名
     * @param status   当前状态
     * @return {@link CertSnapshot} 快照
     */
    private CertSnapshot cert(long certId, String certName, String status) {
        return new CertSnapshot(certId, certName, status);
    }

    @Test
    void 无声明返回空列表() {
        when(declarationMapper.selectList(any())).thenReturn(List.of());
        assertThat(assembler.of(100L)).isEmpty();
    }

    @Test
    void 多证按挂载顺序输出且state为valid() {
        when(declarationMapper.selectList(any())).thenReturn(List.of(
                declaration(1L, 9L, "家政服务资质"),
                declaration(2L, 10L, "企业营业执照")));
        when(certService.findSnapshot(9L)).thenReturn(cert(9L, "家政服务资质", "approved"));
        when(certService.findSnapshot(10L)).thenReturn(cert(10L, "企业营业执照", "approved"));

        List<PostCredential> credentials = assembler.of(100L);

        assertThat(credentials).hasSize(2);
        assertThat(credentials.get(0).certId()).isEqualTo(9L);
        assertThat(credentials.get(0).certName()).isEqualTo("家政服务资质");
        assertThat(credentials.get(0).state()).isEqualTo("valid");
        assertThat(credentials.get(1).certId()).isEqualTo(10L);
    }

    @Test
    void 已删除的凭证该项不渲染() {
        when(declarationMapper.selectList(any())).thenReturn(List.of(
                declaration(1L, 9L, "家政服务资质"),
                declaration(2L, 10L, "企业营业执照")));
        when(certService.findSnapshot(9L)).thenReturn(null);
        when(certService.findSnapshot(10L)).thenReturn(cert(10L, "企业营业执照", "approved"));

        List<PostCredential> credentials = assembler.of(100L);

        assertThat(credentials).hasSize(1);
        assertThat(credentials.get(0).certId()).isEqualTo(10L);
    }

    @Test
    void 已撤销的凭证该项不渲染() {
        when(declarationMapper.selectList(any())).thenReturn(List.of(declaration(1L, 9L, "家政服务资质")));
        when(certService.findSnapshot(9L)).thenReturn(cert(9L, "家政服务资质", "rejected"));

        assertThat(assembler.of(100L)).isEmpty();
    }

    @Test
    void 整体替换先清空再按入参写快照并去重() {
        assembler.replaceAll(100L, List.of(
                cert(9L, "家政服务资质", "approved"),
                cert(10L, "企业营业执照", "approved"),
                cert(9L, "家政服务资质", "approved")));

        verify(declarationMapper).delete(any());
        ArgumentCaptor<PostCertDeclarationEntity> captor =
                ArgumentCaptor.forClass(PostCertDeclarationEntity.class);
        verify(declarationMapper, times(2)).insert(captor.capture());
        assertThat(captor.getAllValues()).extracting(PostCertDeclarationEntity::getCertId)
                .containsExactly(9L, 10L);
        assertThat(captor.getAllValues().get(0).getCertNameSnapshot()).isEqualTo("家政服务资质");
        assertThat(captor.getAllValues().get(0).getPostId()).isEqualTo(100L);
    }

    @Test
    void 空集合只清空不插入() {
        assembler.replaceAll(100L, List.of());

        verify(declarationMapper).delete(any());
        verify(declarationMapper, never()).insert(any(PostCertDeclarationEntity.class));
    }
}
