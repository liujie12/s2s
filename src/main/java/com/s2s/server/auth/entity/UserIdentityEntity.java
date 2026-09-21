package com.s2s.server.auth.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 登录身份归一化映射实体（[123] U2；映射表 {@code user_identity}）。
 *
 * <p>职责：承载 {@code user_identity} 表一行，是「手机号 / 微信 / Apple」多身份
 * 归一化到同一 {@code user_id} 的持久层载体。字段与 {@code V1__init_schema.sql}
 * 第 57–69 行<b>逐列</b>对齐。</p>
 *
 * <p>盲索引双列范式（详设 §4.1 / 数据库设计文档 §7.1）：
 * {@code identity_hash}（HMAC-SHA256+pepper，确定性，承载 {@code uk_type_hash}
 * 等值查询）+ {@code identity_value_enc}（AES-GCM-256 随机 IV，仅解密展示）+
 * {@code key_version}（独立列，解密时按版本取密钥）。三者必须<b>同事务</b>写入，
 * 任一缺失即破坏「命中唯一索引 → 取 user_id」的登录主路径。</p>
 *
 * <p>类型映射：{@code BINARY(32)} / {@code VARBINARY} → {@code byte[]}；
 * {@code ENUM} → {@link String}（U2 决策）；{@code TINYINT} → {@link Integer}；
 * {@code BIGINT} → {@link Long}；{@code DATETIME} → {@link LocalDateTime}。</p>
 *
 * <p>AAD 绑定提醒（安全 §9.6）：{@code identity_value_enc} 的 AAD 为
 * {@code user_id + identity_type}，故写入前必须<b>先拿到 user_id</b>再加密
 * （详设 §5.1 登录流程已标注该顺序依赖）。</p>
 *
 * <p>出处：详设 §13.2、数据库设计文档 §5.1、编码规范 §4.8（加解密）。</p>
 */
@TableName("user_identity")
public class UserIdentityEntity {

    /** 身份行 ID（主键，数据库 AUTO_INCREMENT 自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 指向 user.id；多条身份共用同一 user_id 即同一自然人。 */
    private Long userId;

    /** 身份类型：{@code phone/wechat/apple}；Batch1 只写 phone。 */
    private String identityType;

    /** 身份值 HMAC-SHA256+pepper 盲索引（{@code BINARY(32)}，承载等值查询与唯一索引）。 */
    private byte[] identityHash;

    /** 身份值 AEAD 密文（{@code VARBINARY(255)}，随机 IV，仅用于解密展示）。 */
    private byte[] identityValueEnc;

    /** 加解密所用密钥版本号（{@code TINYINT}）。 */
    private Integer keyVersion;

    /** 绑定时间（数据库默认 CURRENT_TIMESTAMP）。 */
    private LocalDateTime createdAt;

    /**
     * 返回身份行 ID。
     *
     * @return 身份行 ID（主键）
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置身份行 ID。
     *
     * @param id 身份行 ID
     */
    public void setId(Long id) {
        this.id = id;
    }

    /**
     * 返回所属用户 ID。
     *
     * @return 所属 user.id
     */
    public Long getUserId() {
        return userId;
    }

    /**
     * 设置所属用户 ID。
     *
     * @param userId 所属 user.id
     */
    public void setUserId(Long userId) {
        this.userId = userId;
    }

    /**
     * 返回身份类型。
     *
     * @return 身份类型（{@code phone/wechat/apple}）
     */
    public String getIdentityType() {
        return identityType;
    }

    /**
     * 设置身份类型。
     *
     * @param identityType 身份类型
     */
    public void setIdentityType(String identityType) {
        this.identityType = identityType;
    }

    /**
     * 返回身份值盲索引。
     *
     * @return 身份值 HMAC 盲索引字节
     */
    public byte[] getIdentityHash() {
        return identityHash;
    }

    /**
     * 设置身份值盲索引。
     *
     * @param identityHash 身份值 HMAC 盲索引字节
     */
    public void setIdentityHash(byte[] identityHash) {
        this.identityHash = identityHash;
    }

    /**
     * 返回身份值 AEAD 密文。
     *
     * @return 身份值密文字节
     */
    public byte[] getIdentityValueEnc() {
        return identityValueEnc;
    }

    /**
     * 设置身份值 AEAD 密文。
     *
     * @param identityValueEnc 身份值密文字节
     */
    public void setIdentityValueEnc(byte[] identityValueEnc) {
        this.identityValueEnc = identityValueEnc;
    }

    /**
     * 返回加解密密钥版本号。
     *
     * @return 密钥版本号
     */
    public Integer getKeyVersion() {
        return keyVersion;
    }

    /**
     * 设置加解密密钥版本号。
     *
     * @param keyVersion 密钥版本号
     */
    public void setKeyVersion(Integer keyVersion) {
        this.keyVersion = keyVersion;
    }

    /**
     * 返回绑定时间。
     *
     * @return 绑定时间
     */
    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    /**
     * 设置绑定时间。
     *
     * @param createdAt 绑定时间
     */
    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
