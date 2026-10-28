package com.s2s.server.post.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 帖级凭证声明实体（V22 新表 {@code post_cert_declaration}）。
 *
 * <p>职责：一条帖子最多一条声明记录，携带发布/补挂瞬间的资质快照。快照列只在写入时落值，
 * 之后换证、改名都不回溯——详情页主行恒为「发布时事实」。</p>
 *
 * <p><b>V23</b>：资质取消「类型 + 有效期」，本表随之删除 {@code cert_type}、
 * {@code expire_at_snapshot}、{@code expire_type_snapshot}、{@code cert_status_snapshot}，
 * 只留证名快照。</p>
 *
 * <p>为什么独立成表而不是给 {@code post} 加可空列：补挂不能改 {@code post} 行，否则
 * 「补挂不改帖子时间」只能靠约定守住；一帖一证由 {@code uk_post} 在结构上保证。</p>
 */
@TableName("post_cert_declaration")
public class PostCertDeclarationEntity {

    /** 声明记录 ID（主键，数据库 AUTO_INCREMENT）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 帖子 ID（唯一键 {@code uk_post}：一帖最多一条）。 */
    private Long postId;

    /** 引用的 cert ID；证书被删除后行内保留原值，读取侧按「记录不存在」判为已失效。 */
    private Long certId;

    /** 证名快照（永不改写）。 */
    private String certNameSnapshot;

    /** 声明时间（发布时或补挂时）。 */
    private LocalDateTime declaredAt;

    /** 行更新时间（补挂替换时刷新，由数据库 ON UPDATE 维护）。 */
    private LocalDateTime updatedAt;

    /**
     * 返回声明记录 ID。
     *
     * @return 声明记录 ID
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置声明记录 ID。
     *
     * @param id 声明记录 ID
     */
    public void setId(Long id) {
        this.id = id;
    }

    /**
     * 返回帖子 ID。
     *
     * @return 帖子 ID
     */
    public Long getPostId() {
        return postId;
    }

    /**
     * 设置帖子 ID。
     *
     * @param postId 帖子 ID
     */
    public void setPostId(Long postId) {
        this.postId = postId;
    }

    /**
     * 返回引用的 cert ID。
     *
     * @return cert ID（证书删除后仍保留原值）
     */
    public Long getCertId() {
        return certId;
    }

    /**
     * 设置引用的 cert ID。
     *
     * @param certId cert ID
     */
    public void setCertId(Long certId) {
        this.certId = certId;
    }

    /**
     * 返回证名快照。
     *
     * @return 证名快照
     */
    public String getCertNameSnapshot() {
        return certNameSnapshot;
    }

    /**
     * 设置证名快照。
     *
     * @param certNameSnapshot 证名快照
     */
    public void setCertNameSnapshot(String certNameSnapshot) {
        this.certNameSnapshot = certNameSnapshot;
    }

    /**
     * 返回声明时间。
     *
     * @return 声明时间
     */
    public LocalDateTime getDeclaredAt() {
        return declaredAt;
    }

    /**
     * 设置声明时间。
     *
     * @param declaredAt 声明时间
     */
    public void setDeclaredAt(LocalDateTime declaredAt) {
        this.declaredAt = declaredAt;
    }

    /**
     * 返回行更新时间。
     *
     * @return 行更新时间
     */
    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    /**
     * 设置行更新时间。
     *
     * @param updatedAt 行更新时间
     */
    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
