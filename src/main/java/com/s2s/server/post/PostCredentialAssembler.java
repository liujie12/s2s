package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.post.dto.PostCredential;
import com.s2s.server.post.entity.PostCertDeclarationEntity;
import com.s2s.server.post.mapper.PostCertDeclarationMapper;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
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
 */
@Component
public class PostCredentialAssembler {

    /** 展示状态：有效。 */
    private static final String STATE_VALID = "valid";

    /** 展示状态：已到期。 */
    private static final String STATE_EXPIRED = "expired";

    /** 展示状态：被撤销（凭证状态为 {@code rejected}，本轮不产生新数据，兼容历史行）。 */
    private static final String STATE_REVOKED = "revoked";

    /** 展示状态：凭证已被用户删除。 */
    private static final String STATE_DELETED = "deleted";

    /** 凭证状态：已通过。 */
    private static final String CERT_STATUS_APPROVED = "approved";

    /** 凭证状态：已过期。 */
    private static final String CERT_STATUS_EXPIRED = "expired";

    /** 凭证状态：已驳回（历史审核口径，映射为「被撤销」）。 */
    private static final String CERT_STATUS_REJECTED = "rejected";

    /** 有效期类型：有到期日。 */
    private static final String EXPIRE_TYPE_DATED = "dated";

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
            entity.setCertType(snapshot.certType());
            entity.setCertNameSnapshot(snapshot.certName() == null ? "" : snapshot.certName());
            entity.setExpireAtSnapshot(snapshot.expireAt());
            entity.setExpireTypeSnapshot(snapshot.expireType());
            entity.setCertStatusSnapshot(snapshot.status());
            entity.setDeclaredAt(LocalDateTime.now());
            declarationMapper.insert(entity);
            return;
        }
        declarationMapper.update(null, new UpdateWrapper<PostCertDeclarationEntity>()
                .eq("id", existing.getId())
                .set("cert_id", snapshot.certId())
                .set("cert_type", snapshot.certType())
                .set("cert_name_snapshot", snapshot.certName() == null ? "" : snapshot.certName())
                .set("expire_at_snapshot", snapshot.expireAt())
                .set("expire_type_snapshot", snapshot.expireType())
                .set("cert_status_snapshot", snapshot.status())
                .set("declared_at", LocalDateTime.now()));
    }

    /**
     * 组装详情页凭证块（无声明或脏数据返回 {@code null}，客户端整块不渲染）。
     *
     * <p>脏数据判据：关联瞬间凭证就已失效（{@code cert_status_snapshot != approved}）——
     * 主行与说明行一起不渲染，避免出现「只有说明行没有主行」的残句。</p>
     *
     * @param postId 帖子 ID
     * @return {@link PostCredential} 凭证块；无声明/脏数据返回 {@code null}
     */
    public PostCredential of(Long postId) {
        PostCertDeclarationEntity declaration = findByPostId(postId);
        if (declaration == null
                || !CERT_STATUS_APPROVED.equals(declaration.getCertStatusSnapshot())) {
            return null;
        }
        CertSnapshot cert = certService.findSnapshot(declaration.getCertId());
        return new PostCredential(
                declaration.getCertType(),
                declaration.getCertNameSnapshot(),
                declaration.getExpireTypeSnapshot(),
                toInstant(declaration.getExpireAtSnapshot()),
                stateOf(cert),
                toInstant(declaration.getDeclaredAt()));
    }

    /**
     * 按凭证当前状态派生展示状态。
     *
     * @param cert 凭证当前快照；{@code null} 表示记录已被删除
     * @return {@link String} {@code valid/expired/revoked/deleted}
     */
    private String stateOf(CertSnapshot cert) {
        if (cert == null) {
            return STATE_DELETED;
        }
        if (CERT_STATUS_REJECTED.equals(cert.status())) {
            return STATE_REVOKED;
        }
        if (CERT_STATUS_EXPIRED.equals(cert.status())) {
            return STATE_EXPIRED;
        }
        if (EXPIRE_TYPE_DATED.equals(cert.expireType()) && cert.expireAt() != null
                && !cert.expireAt().isAfter(LocalDateTime.now())) {
            return STATE_EXPIRED;
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

    /**
     * 库内时间转 API 时间（UTC 时刻）。
     *
     * @param time 库内时间
     * @return {@link Instant} UTC 时刻；入参 {@code null} 返回 {@code null}
     */
    private Instant toInstant(LocalDateTime time) {
        return time == null ? null : time.atZone(ZoneId.systemDefault()).toInstant();
    }
}
