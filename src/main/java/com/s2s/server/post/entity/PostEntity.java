package com.s2s.server.post.entity;

import com.baomidou.mybatisplus.annotation.FieldStrategy;
import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import com.baomidou.mybatisplus.annotation.Version;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 发布信息实体（[125]；映射表 {@code post}）。
 *
 * <p>职责：承载 {@code post} 表一行，是 post 域发布链的持久层载体。
 * 字段与 {@code V1__init_schema.sql} 第 152–199 行<b>逐列</b>对齐。</p>
 *
 * <p>两个 STORED 生成列（{@code l2_category_id}、{@code completeness_level}）
 * 由数据库自动派生，<b>禁入 insert/update SQL</b>（否则 {@code ERROR 3105}），
 * 故标注 {@link FieldStrategy#NEVER}（编码规范 §4.9）。</p>
 *
 * <p>契约名→列名漂移（KTD4）：openapi {@code description}→列 {@code desc}、
 * {@code attributes}→列 {@code template_values}；本实体用 Java 语义字段名
 * 经 {@link TableField} 显式映射，DTO 层保持契约名。</p>
 */
@TableName("post")
public class PostEntity {

    /** 帖子 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 发布者 user_id。 */
    private Long userId;

    /** 类型：resource 资源 / demand 需求。 */
    private String type;

    /** 叶子类目 ID（L3，驱动模板与详情渲染）。 */
    private Integer leafCategoryId;

    /** 二级类目 ID（STORED 生成列，只读，禁写）。 */
    @TableField(value = "l2_category_id", insertStrategy = FieldStrategy.NEVER,
            updateStrategy = FieldStrategy.NEVER)
    private Integer l2CategoryId;

    /** 标题（过敏感词校验）。 */
    private String title;

    /** 描述正文（过敏感词校验）；列名 {@code desc}。 */
    @TableField("desc")
    private String description;

    /** 约 500m 网格 ID 字符串 gx_gy。 */
    private String gridId;

    /** 价格（NULL 表示面议）。 */
    private BigDecimal price;

    /** 价格单位（取模板 price_units 之一）。 */
    private String priceUnit;

    /** GCJ-02 经度（仅发布点）。 */
    private BigDecimal lng;

    /** GCJ-02 纬度（仅发布点）。 */
    private BigDecimal lat;

    /** 门牌号地址（影响完整度档）。 */
    private String address;

    /** 模板字段实际值 JSON；列名 {@code template_values}。 */
    @TableField("template_values")
    private String templateValues;

    /** 联系方式渠道（phone/wechat 二选一）。 */
    private String contactChannel;

    /** 联系方式 AEAD 密文（VARBINARY）。 */
    private byte[] contactValueEnc;

    /** 三条件达成态 JSON {required_full, address_precise, leaf_matched}。 */
    private String completenessConditions;

    /** 完整度档位 0=红/1=黄/2=绿（STORED 生成列，只读，禁写）。 */
    @TableField(value = "completeness_level", insertStrategy = FieldStrategy.NEVER,
            updateStrategy = FieldStrategy.NEVER)
    private Integer completenessLevel;

    /** 未实名先发后审受限态。 */
    private Integer restricted;

    /** 状态机：draft/active/archived/hidden。 */
    private String status;

    /** 进入非 active 路径：0=主动下架/1=到期/2=审核下架/3=成交。 */
    private Integer statusReason;

    /** status 变更时刻。 */
    private LocalDateTime statusChangedAt;

    /** 发布时模板版本号。 */
    private Integer templateVersion;

    /** 风险分累计，≥60 自动下架。 */
    private Integer riskScore;

    /** 到期时间（默认 +7 天）。 */
    private LocalDateTime expireAt;

    /** 乐观锁版本号（@Version）。 */
    @Version
    private Long version;

    /** 联系方式 AEAD 密钥版本号。 */
    private Integer keyVersion;

    /** 创建时间。 */
    private LocalDateTime createdAt;

    /** 更新时间。 */
    private LocalDateTime updatedAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public String getType() {
        return type;
    }

    public void setType(String type) {
        this.type = type;
    }

    public Integer getLeafCategoryId() {
        return leafCategoryId;
    }

    public void setLeafCategoryId(Integer leafCategoryId) {
        this.leafCategoryId = leafCategoryId;
    }

    public Integer getL2CategoryId() {
        return l2CategoryId;
    }

    public void setL2CategoryId(Integer l2CategoryId) {
        this.l2CategoryId = l2CategoryId;
    }

    public String getTitle() {
        return title;
    }

    public void setTitle(String title) {
        this.title = title;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    public String getGridId() {
        return gridId;
    }

    public void setGridId(String gridId) {
        this.gridId = gridId;
    }

    public BigDecimal getPrice() {
        return price;
    }

    public void setPrice(BigDecimal price) {
        this.price = price;
    }

    public String getPriceUnit() {
        return priceUnit;
    }

    public void setPriceUnit(String priceUnit) {
        this.priceUnit = priceUnit;
    }

    public BigDecimal getLng() {
        return lng;
    }

    public void setLng(BigDecimal lng) {
        this.lng = lng;
    }

    public BigDecimal getLat() {
        return lat;
    }

    public void setLat(BigDecimal lat) {
        this.lat = lat;
    }

    public String getAddress() {
        return address;
    }

    public void setAddress(String address) {
        this.address = address;
    }

    public String getTemplateValues() {
        return templateValues;
    }

    public void setTemplateValues(String templateValues) {
        this.templateValues = templateValues;
    }

    public String getContactChannel() {
        return contactChannel;
    }

    public void setContactChannel(String contactChannel) {
        this.contactChannel = contactChannel;
    }

    public byte[] getContactValueEnc() {
        return contactValueEnc;
    }

    public void setContactValueEnc(byte[] contactValueEnc) {
        this.contactValueEnc = contactValueEnc;
    }

    public String getCompletenessConditions() {
        return completenessConditions;
    }

    public void setCompletenessConditions(String completenessConditions) {
        this.completenessConditions = completenessConditions;
    }

    public Integer getCompletenessLevel() {
        return completenessLevel;
    }

    public void setCompletenessLevel(Integer completenessLevel) {
        this.completenessLevel = completenessLevel;
    }

    public Integer getRestricted() {
        return restricted;
    }

    public void setRestricted(Integer restricted) {
        this.restricted = restricted;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Integer getStatusReason() {
        return statusReason;
    }

    public void setStatusReason(Integer statusReason) {
        this.statusReason = statusReason;
    }

    public LocalDateTime getStatusChangedAt() {
        return statusChangedAt;
    }

    public void setStatusChangedAt(LocalDateTime statusChangedAt) {
        this.statusChangedAt = statusChangedAt;
    }

    public Integer getTemplateVersion() {
        return templateVersion;
    }

    public void setTemplateVersion(Integer templateVersion) {
        this.templateVersion = templateVersion;
    }

    public Integer getRiskScore() {
        return riskScore;
    }

    public void setRiskScore(Integer riskScore) {
        this.riskScore = riskScore;
    }

    public LocalDateTime getExpireAt() {
        return expireAt;
    }

    public void setExpireAt(LocalDateTime expireAt) {
        this.expireAt = expireAt;
    }

    public Long getVersion() {
        return version;
    }

    public void setVersion(Long version) {
        this.version = version;
    }

    public Integer getKeyVersion() {
        return keyVersion;
    }

    public void setKeyVersion(Integer keyVersion) {
        this.keyVersion = keyVersion;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }

    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
