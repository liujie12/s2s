package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.post.dto.PostCredential;
import com.s2s.server.post.entity.PostCertDeclarationEntity;
import com.s2s.server.post.mapper.PostCertDeclarationMapper;
import java.time.LocalDateTime;
import org.springframework.stereotype.Component;

/**
 * 帖级凭证声明的读写与展示状态派生（V22；详情页资质行唯一组装点）。
 *
 * <p><b>为什么单独一处</b>：发布、补挂、详情三处都要碰声明记录，若各写一遍「写快照」
 * 与「按当前状态派生说明行」，三处迟早会漂移。此处把「写入冻结快照」与「读取时组装」
 * 收敛成一对，主行与说明行的口径只在这里定义。</p>
 *
 * <p><b>跨域边界</b>：凭证当前状态经 {@link CertService#findSnapshot} 读取，
 * 本类不接触 {@code cert} 表（编码规范 §4.2）。</p>
 *
 * <p><b>V23 简化</b>：资质取消「类型 + 有效期」，声明表只留证名快照；详情凭证块只显示
 * 证名，凭证非有效（撤销/删除）时整块不渲染。</p>
 */
@Component
public class PostCredentialAssembler {

    /** 展示状态：有效。 */
    private static final String STATE_VALID = "valid";

    /** 展示状态：被撤销（凭证状态为 {@code rejected}，本轮不产生新数据，兼容历史行）。 */
    private static final String STATE_REVOKED = "revoked";

    /** 展示状态：凭证已被用户删除。 */
    private static final String STATE_DELETED = "deleted";

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
     * 写入或替换一条声明记录（发布与补挂共用）。
     *
     * <p>已有记录时按替换处理：快照重取、{@code declared_at} 刷新；
     * <b>不修改 {@code post} 行</b>（补挂不改帖子时间、不进排序权重）。</p>
     *
     * @param postId   帖子 ID
     * @param snapshot 挂载瞬间的资质快照（调用方已完成可挂载校验）
     */
    public void upsert(Long postId, CertSnapshot snapshot) {
        PostCertDeclarationEntity existing = findByPostId(postId);
        if (existing == null) {
            PostCertDeclarationEntity entity = new PostCertDeclarationEntity();
            entity.setPostId(postId);
            entity.setCertId(snapshot.certId());
            entity.setCertNameSnapshot(snapshot.certName() == null ? "" : snapshot.certName());
            entity.setDeclaredAt(LocalDateTime.now());
            declarationMapper.insert(entity);
            return;
        }
        declarationMapper.update(null, new UpdateWrapper<PostCertDeclarationEntity>()
                .eq("id", existing.getId())
                .set("cert_id", snapshot.certId())
                .set("cert_name_snapshot", snapshot.certName() == null ? "" : snapshot.certName())
                .set("declared_at", LocalDateTime.now()));
    }

    /**
     * 组装详情页凭证块（无声明或凭证非有效返回 {@code null}，客户端整块不渲染）。
     *
     * <p>只有凭证当前 {@code approved} 才渲染：证照记录不存在（已删除）或被撤销时，
     * 主行与说明行一起不渲染，避免出现「只有说明行没有主行」的残句。</p>
     *
     * @param postId 帖子 ID
     * @return {@link PostCredential} 凭证块（{@link #STATE_VALID}）；无声明/非有效返回 {@code null}
     */
    public PostCredential of(Long postId) {
        PostCertDeclarationEntity declaration = findByPostId(postId);
        if (declaration == null) {
            return null;
        }
        CertSnapshot cert = certService.findSnapshot(declaration.getCertId());
        String state = stateOf(cert);
        if (!STATE_VALID.equals(state)) {
            return null;
        }
        return new PostCredential(declaration.getCertNameSnapshot(), state);
    }

    /**
     * 按凭证当前状态派生展示状态。
     *
     * @param cert 凭证当前快照；{@code null} 表示记录已被删除
     * @return {@link String} {@code valid/revoked/deleted}
     */
    private String stateOf(CertSnapshot cert) {
        if (cert == null) {
            return STATE_DELETED;
        }
        if (!CERT_STATUS_APPROVED.equals(cert.status())) {
            return STATE_REVOKED;
        }
        return STATE_VALID;
    }

    /**
     * 按帖子 ID 取声明记录。
     *
     * @param postId 帖子 ID
     * @return {@link PostCertDeclarationEntity} 声明记录；不存在返回 {@code null}
     */
    private PostCertDeclarationEntity findByPostId(Long postId) {
        return declarationMapper.selectOne(new QueryWrapper<PostCertDeclarationEntity>()
                .eq("post_id", postId));
    }
}
