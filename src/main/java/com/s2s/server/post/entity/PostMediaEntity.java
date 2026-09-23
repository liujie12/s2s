package com.s2s.server.post.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 帖子媒体实体（[125]；映射表 {@code post_media}）。
 *
 * <p>职责：承载 {@code post_media} 表一行，是 OSS 两步直传登记 + 媒体审核的持久层载体。
 * 字段与 {@code V1__init_schema.sql} 第 206–218 行对齐，另含 V2 迁移新增的
 * {@code user_id} 归属列（KTD8）。</p>
 *
 * <p>{@code audit_status} 三态（{@code pending}/{@code pass}/{@code reject}）双视角：
 * {@code audit_status != pass} 的媒体不得出现在非本人可见响应中
 * （{@code MediaAssembler.toDto(entity, isOwner)} 视角分流）。</p>
 */
@TableName("post_media")
public class PostMediaEntity {

    /** 媒体 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 关联 post.id；未关联时为孤儿 media（编辑态）。 */
    private Long postId;

    /** 媒体上传者 user_id（V2 迁移新增，归属校验用）。 */
    private Long userId;

    /** OSS 对象键（服务端 UUID 生成）。 */
    private String objectKey;

    /** 内容审核状态：pending/pass/reject。 */
    private String auditStatus;

    /** 审核拒绝原因。 */
    private String rejectReason;

    /** MIME 类型。 */
    private String contentType;

    /** 文件字节数。 */
    private Integer sizeBytes;

    /** 创建时间。 */
    private LocalDateTime createdAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getPostId() {
        return postId;
    }

    public void setPostId(Long postId) {
        this.postId = postId;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public String getObjectKey() {
        return objectKey;
    }

    public void setObjectKey(String objectKey) {
        this.objectKey = objectKey;
    }

    public String getAuditStatus() {
        return auditStatus;
    }

    public void setAuditStatus(String auditStatus) {
        this.auditStatus = auditStatus;
    }

    public String getRejectReason() {
        return rejectReason;
    }

    public void setRejectReason(String rejectReason) {
        this.rejectReason = rejectReason;
    }

    public String getContentType() {
        return contentType;
    }

    public void setContentType(String contentType) {
        this.contentType = contentType;
    }

    public Integer getSizeBytes() {
        return sizeBytes;
    }

    public void setSizeBytes(Integer sizeBytes) {
        this.sizeBytes = sizeBytes;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
