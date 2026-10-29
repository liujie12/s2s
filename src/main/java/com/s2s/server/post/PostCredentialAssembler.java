package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.post.dto.PostCredential;
import com.s2s.server.post.entity.PostCertDeclarationEntity;
import com.s2s.server.post.mapper.PostCertDeclarationMapper;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.springframework.stereotype.Component;

/**
 * 帖级凭证声明的读写与展示状态派生（V22；V25 起一帖多证；详情页资质栏唯一组装点）。
 *
 * <p><b>为什么单独一处</b>：发布、编辑、补挂、详情四处都要碰声明记录，若各写一遍「写快照」
 * 与「按当前状态派生说明行」，四处迟早会漂移。此处把「整体替换冻结快照」与「读取时组装」
 * 收敛成一对，主行与说明行的口径只在这里定义。</p>
 *
 * <p><b>跨域边界</b>：凭证当前状态经 {@link CertService#findSnapshot} 读取，
 * 本类不接触 {@code cert} 表（编码规范 §4.2）。</p>
 *
 * <p><b>展示口径</b>：详情只显示证名；凭证被删除或撤销时该项整条剔除，
 * 避免出现「只有说明行没有主行」的残句。全部失效时返回空列表，客户端整栏不渲染。</p>
 */
@Component
public class PostCredentialAssembler {

    /** 展示状态：有效。 */
    private static final String STATE_VALID = "valid";

    /** 凭证状态：已通过。 */
    private static final String CERT_STATUS_APPROVED = "approved";

    private final PostCertDeclarationMapper declarationMapper;

    private final CertService certService;

    /**
     * 构造声明组装器。
     *
     * @param declarationMapper 声明表 Mapper
     * @param certService       资质服务（读当前状态，跨域只调 service）
     */
    public PostCredentialAssembler(PostCertDeclarationMapper declarationMapper,
            CertService certService) {
        this.declarationMapper = declarationMapper;
        this.certService = certService;
    }

    /**
     * 整体替换一条帖子的资质声明集合（发布、编辑、补挂共用）。
     *
     * <p>语义为「该帖最终集合」：先清空本贴全部声明行，再按入参顺序逐张写入快照，
     * 因此 {@code declared_at} 会整体刷新；<b>不修改 {@code post} 行</b>
     * （补挂不改帖子时间、不进排序权重）。空集合等价于取消全部挂载。</p>
     *
     * @param postId    帖子 ID
     * @param snapshots 挂载瞬间的资质快照列表（调用方已完成可挂载校验；允许空列表）
     */
    public void replaceAll(Long postId, List<CertSnapshot> snapshots) {
        declarationMapper.delete(new QueryWrapper<PostCertDeclarationEntity>()
                .eq("post_id", postId));

        // 去重按 cert_id：同一张资质不重复挂载（与 uk_post_cert 结构约束一致）
        Set<Long> seen = new LinkedHashSet<>();
        LocalDateTime now = LocalDateTime.now();
        for (CertSnapshot snapshot : snapshots) {
            if (!seen.add(snapshot.certId())) {
                continue;
            }
            PostCertDeclarationEntity entity = new PostCertDeclarationEntity();
            entity.setPostId(postId);
            entity.setCertId(snapshot.certId());
            entity.setCertNameSnapshot(snapshot.certName() == null ? "" : snapshot.certName());
            entity.setDeclaredAt(now);
            declarationMapper.insert(entity);
        }
    }

    /**
     * 组装详情页资质栏（按声明顺序返回全部当前有效的证名）。
     *
     * <p>只有凭证当前 {@code approved} 才返回：证照记录不存在（已删除）或被撤销时该项剔除。</p>
     *
     * @param postId 帖子 ID
     * @return {@link List} 凭证项列表；无声明或全部失效返回空列表
     */
    public List<PostCredential> of(Long postId) {
        List<PostCertDeclarationEntity> declarations = listByPostId(postId);
        if (declarations.isEmpty()) {
            return List.of();
        }
        List<PostCredential> result = new ArrayList<>(declarations.size());
        for (PostCertDeclarationEntity declaration : declarations) {
            CertSnapshot cert = certService.findSnapshot(declaration.getCertId());
            if (!isValid(cert)) {
                continue;
            }
            result.add(new PostCredential(declaration.getCertId(),
                    declaration.getCertNameSnapshot(), STATE_VALID, cert.imageUrl()));
        }
        return result;
    }

    /**
     * 判断凭证当前是否有效（{@code approved}）。
     *
     * @param cert 凭证当前快照；{@code null} 表示记录已被删除
     * @return {@code true} 表示可展示
     */
    private boolean isValid(CertSnapshot cert) {
        return cert != null && CERT_STATUS_APPROVED.equals(cert.status());
    }

    /**
     * 按帖子 ID 取出全部声明记录（按 ID 升序 = 挂载顺序）。
     *
     * @param postId 帖子 ID
     * @return {@link List} 声明记录列表；无记录返回空列表
     */
    private List<PostCertDeclarationEntity> listByPostId(Long postId) {
        return declarationMapper.selectList(new QueryWrapper<PostCertDeclarationEntity>()
                .eq("post_id", postId)
                .orderByAsc("id"));
    }
}
