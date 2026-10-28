package com.s2s.server.cert.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 认证记录实体（[149]；映射表 {@code cert}）。
 *
 * <p>职责：承载 {@code cert} 表一行——每次实名/资质申请的原始记录；{@code user} 表存
 * 最新聚合态（{@code realname_status}），本表存每次申请（含失败计数与防刷锁定）。字段与
 * {@code V1__init_schema.sql} 第 306–322 行<b>逐列</b>对齐后，再经
 * {@code V23__cert_drop_type_and_expire.sql} 删除 {@code expire_type}/{@code expire_at}
 * （资质取消有效期概念），故当前不含有效期字段（编码规范 §4.2 entity 层口径）。</p>
 *
 * <p>类型映射（详设 §7）：{@code ENUM} → {@link String}、{@code DATETIME} →
 * {@link LocalDateTime}、{@code TINYINT} → {@link Integer}、{@code BIGINT} → {@link Long}。</p>
 *
 * <p>主键：{@code id} 由数据库 {@code AUTO_INCREMENT} 生成，{@link TableId} 用
 * {@link IdType#AUTO}（MyBatis-Plus 默认雪花 ID 会覆盖数据库自增）。</p>
 *
 * <p>出处：详设 §13.2（字段字典）、数据库设计文档 §5.1、编码规范 §4.2（分层与域边界）。</p>
 */
@TableName("cert")
public class CertEntity {

    /** 认证 ID（主键，数据库 AUTO_INCREMENT 自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 申请人 user_id。 */
    private Long userId;

    /** 认证类型：{@code personal_realname/personal_qualification/enterprise/vehicle}。 */
    private String certType;

    /** 证书名称（OCR 读取后经用户确认，展示用；可空）。 */
    private String certName;

    /** 证名来源：{@code ocr}=自动读取；{@code manual}=用户手填或改写（可空）。 */
    private String nameSource;

    /** 认证状态：{@code pending/approved/rejected}（V23 起取消 {@code expired}）。 */
    private String status;

    /** 提交时间（数据库默认 CURRENT_TIMESTAMP）。 */
    private LocalDateTime submittedAt;

    /** 审核通过时间（可空）。 */
    private LocalDateTime approvedAt;

    /** 审核拒绝原因（可空）。 */
    private String rejectReason;

    /** OCR 原始证照图 OSS 引用（可空；随资质删除时一并清理）。 */
    private String ocrImageRef;

    /** 该用户该类型认证失败次数（默认 0）。 */
    private Integer failCount;

    /** 锁定到（可空，防刷）。 */
    private LocalDateTime lockUntil;

    /**
     * 返回认证 ID。
     *
     * @return 认证 ID（主键）
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置认证 ID。
     *
     * @param id 认证 ID
     */
    public void setId(Long id) {
        this.id = id;
    }

    /**
     * 返回申请人 user_id。
     *
     * @return 申请人 user_id
     */
    public Long getUserId() {
        return userId;
    }

    /**
     * 设置申请人 user_id。
     *
     * @param userId 申请人 user_id
     */
    public void setUserId(Long userId) {
        this.userId = userId;
    }

    /**
     * 返回认证类型。
     *
     * @return 认证类型（{@code personal_realname/personal_qualification/enterprise/vehicle}）
     */
    public String getCertType() {
        return certType;
    }

    /**
     * 设置认证类型。
     *
     * @param certType 认证类型
     */
    public void setCertType(String certType) {
        this.certType = certType;
    }

    /**
     * 返回证书名称。
     *
     * @return 证书名称（可空；历史行为空）
     */
    public String getCertName() {
        return certName;
    }

    /**
     * 设置证书名称。
     *
     * @param certName 证书名称
     */
    public void setCertName(String certName) {
        this.certName = certName;
    }

    /**
     * 返回证名来源。
     *
     * @return 证名来源（{@code ocr}/{@code manual}，可空）
     */
    public String getNameSource() {
        return nameSource;
    }

    /**
     * 设置证名来源。
     *
     * @param nameSource 证名来源（{@code ocr}/{@code manual}）
     */
    public void setNameSource(String nameSource) {
        this.nameSource = nameSource;
    }

    /**
     * 返回认证状态。
     *
     * @return 认证状态（{@code pending/approved/rejected}）
     */
    public String getStatus() {
        return status;
    }

    /**
     * 设置认证状态。
     *
     * @param status 认证状态
     */
    public void setStatus(String status) {
        this.status = status;
    }

    /**
     * 返回提交时间。
     *
     * @return 提交时间
     */
    public LocalDateTime getSubmittedAt() {
        return submittedAt;
    }

    /**
     * 设置提交时间。
     *
     * @param submittedAt 提交时间
     */
    public void setSubmittedAt(LocalDateTime submittedAt) {
        this.submittedAt = submittedAt;
    }

    /**
     * 返回审核通过时间。
     *
     * @return 审核通过时间（可空）
     */
    public LocalDateTime getApprovedAt() {
        return approvedAt;
    }

    /**
     * 设置审核通过时间。
     *
     * @param approvedAt 审核通过时间
     */
    public void setApprovedAt(LocalDateTime approvedAt) {
        this.approvedAt = approvedAt;
    }

    /**
     * 返回审核拒绝原因。
     *
     * @return 审核拒绝原因（可空）
     */
    public String getRejectReason() {
        return rejectReason;
    }

    /**
     * 设置审核拒绝原因。
     *
     * @param rejectReason 审核拒绝原因
     */
    public void setRejectReason(String rejectReason) {
        this.rejectReason = rejectReason;
    }

    /**
     * 返回 OCR 原始证照图 OSS 引用。
     *
     * @return OSS 引用（可空）
     */
    public String getOcrImageRef() {
        return ocrImageRef;
    }

    /**
     * 设置 OCR 原始证照图 OSS 引用。
     *
     * @param ocrImageRef OSS 引用
     */
    public void setOcrImageRef(String ocrImageRef) {
        this.ocrImageRef = ocrImageRef;
    }

    /**
     * 返回失败次数。
     *
     * @return 失败次数（默认 0）
     */
    public Integer getFailCount() {
        return failCount;
    }

    /**
     * 设置失败次数。
     *
     * @param failCount 失败次数
     */
    public void setFailCount(Integer failCount) {
        this.failCount = failCount;
    }

    /**
     * 返回锁定截止时间。
     *
     * @return 锁定截止时间（可空）
     */
    public LocalDateTime getLockUntil() {
        return lockUntil;
    }

    /**
     * 设置锁定截止时间。
     *
     * @param lockUntil 锁定截止时间
     */
    public void setLockUntil(LocalDateTime lockUntil) {
        this.lockUntil = lockUntil;
    }
}
