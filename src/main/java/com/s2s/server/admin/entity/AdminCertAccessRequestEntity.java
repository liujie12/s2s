package com.s2s.server.admin.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 认证原始信息敏感查看双人复核申请实体（映射表 {@code admin_cert_access_request}；
 * [153] B2-5；DDL {@code V13}）。
 *
 * <p>字段与 DDL 逐列对齐。本实体<b>不承载被查看的原始内容</b>——原始信息
 * （{@code cert.ocr_image_ref}）只存于 {@code cert} 表，打开时经 cert 域 service 现取；
 * 本表只记「谁申请看哪条认证、谁复核、结论」（PRD §9.10.1 双人复核）。</p>
 */
@TableName("admin_cert_access_request")
public class AdminCertAccessRequestEntity {

    /** 复核申请 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 目标认证记录 ID（{@code cert.id}）。 */
    private Long certId;

    /** 发起查看的管理员（{@code admin_user.id}）。 */
    private Long requesterId;

    /** 查看理由（必填）。 */
    private String reason;

    /** 复核状态：{@code pending} / {@code approved} / {@code rejected}。 */
    private String status;

    /** 复核人（{@code admin_user.id}；须与发起人不同）。 */
    private Long reviewerId;

    /** 复核时刻。 */
    private LocalDateTime reviewedAt;

    /** 申请时刻（库内默认值，服务端不写）。 */
    private LocalDateTime createdAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getCertId() {
        return certId;
    }

    public void setCertId(Long certId) {
        this.certId = certId;
    }

    public Long getRequesterId() {
        return requesterId;
    }

    public void setRequesterId(Long requesterId) {
        this.requesterId = requesterId;
    }

    public String getReason() {
        return reason;
    }

    public void setReason(String reason) {
        this.reason = reason;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Long getReviewerId() {
        return reviewerId;
    }

    public void setReviewerId(Long reviewerId) {
        this.reviewerId = reviewerId;
    }

    public LocalDateTime getReviewedAt() {
        return reviewedAt;
    }

    public void setReviewedAt(LocalDateTime reviewedAt) {
        this.reviewedAt = reviewedAt;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
