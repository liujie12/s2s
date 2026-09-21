package com.s2s.server.auth.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 用户账号实体（[123] U2；映射表 {@code user}）。
 *
 * <p>职责：承载 {@code user} 表一行，是 auth 域「短信登录 / 本人资料」读写的持久层载体。
 * 字段与 {@code V1__init_schema.sql} 第 31–50 行<b>逐列</b>对齐，无多余列、无遗漏列
 * （编码规范 §4.2「mapper 只做数据访问」的 entity 层口径）。</p>
 *
 * <p>类型映射口径（详设 §7 / 数据库设计文档 §5.1；U2 决策「ENUM → String 最小设施」）：
 * <ul>
 *   <li>{@code BINARY(32)} / {@code VARBINARY} → {@code byte[]}（MyBatis 直接映射，
 *       免 SQL 侧 {@code UNHEX()} 转换点）；</li>
 *   <li>{@code ENUM} → {@link String}（本单元不引入类型化枚举，见 handoff 决策）；</li>
 *   <li>{@code DATETIME} → {@link LocalDateTime}；{@code TINYINT} → {@link Integer}；
 *       {@code BIGINT} → {@link Long}；{@code CHAR(4)} → {@link String}。</li>
 * </ul>
 *
 * <p>数据最小化红线（安全 §9.6）：{@code real_name_enc} / {@code id_card_hash} /
 * {@code id_card_last4} 为敏感列，<b>禁止</b>出现在任何 API 响应中——本实体仅供
 * service/mapper 内部读写，DTO 层负责白名单裁剪（{@code id/nickname/avatar_url/realname_status}）。</p>
 *
 * <p>主键：{@code id} 由数据库 {@code AUTO_INCREMENT} 生成，故 {@link TableId} 用
 * {@link IdType#AUTO}（MyBatis-Plus 默认雪花 ID 会覆盖数据库自增，必须显式声明）。</p>
 *
 * <p>出处：详设 §13.2（字段字典）、数据库设计文档 §5.1、编码规范 §4.2（分层与域边界）。</p>
 */
@TableName("user")
public class UserEntity {

    /** 用户 ID（主键，数据库 AUTO_INCREMENT 自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 手机号脱敏掩码（如 {@code 138****8000}），仅展示；原文落 user_identity 走盲索引。 */
    private String phoneMask;

    /** 昵称。 */
    private String nickname;

    /** 头像 OSS URL（可空）。 */
    private String avatarUrl;

    /** 实名状态：{@code none/pending/passed/rejected}；Batch1 恒 {@code none}。 */
    private String realnameStatus;

    /** 姓名 AEAD 密文（{@code VARBINARY(255)}，可空；仅解密展示，禁止出现在响应）。 */
    private byte[] realNameEnc;

    /** 身份证号 HMAC-SHA256+pepper 盲索引（{@code BINARY(32)}，可空，不可逆）。 */
    private byte[] idCardHash;

    /** 身份证后 4 位明文（{@code CHAR(4)}，可空；用户自查与客服核对）。 */
    private String idCardLast4;

    /** 默认搜索半径档：{@code 1/3/5/10/city}；默认 {@code 3}。 */
    private String defaultRadius;

    /** 注销发起时间（可空；+7 天冷静期）。 */
    private LocalDateTime deactivateAt;

    /** 加解密所用密钥版本号（{@code TINYINT}，支持灰度轮换）；默认 0。 */
    private Integer keyVersion;

    /** 创建时间（数据库默认 CURRENT_TIMESTAMP）。 */
    private LocalDateTime createdAt;

    /** 更新时间（数据库默认 CURRENT_TIMESTAMP ON UPDATE）。 */
    private LocalDateTime updatedAt;

    /**
     * 返回用户 ID。
     *
     * @return 用户 ID（主键）
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置用户 ID。
     *
     * @param id 用户 ID
     */
    public void setId(Long id) {
        this.id = id;
    }

    /**
     * 返回手机号脱敏掩码。
     *
     * @return 手机号脱敏掩码
     */
    public String getPhoneMask() {
        return phoneMask;
    }

    /**
     * 设置手机号脱敏掩码。
     *
     * @param phoneMask 手机号脱敏掩码
     */
    public void setPhoneMask(String phoneMask) {
        this.phoneMask = phoneMask;
    }

    /**
     * 返回昵称。
     *
     * @return 昵称
     */
    public String getNickname() {
        return nickname;
    }

    /**
     * 设置昵称。
     *
     * @param nickname 昵称
     */
    public void setNickname(String nickname) {
        this.nickname = nickname;
    }

    /**
     * 返回头像 OSS URL。
     *
     * @return 头像 OSS URL（可空）
     */
    public String getAvatarUrl() {
        return avatarUrl;
    }

    /**
     * 设置头像 OSS URL。
     *
     * @param avatarUrl 头像 OSS URL
     */
    public void setAvatarUrl(String avatarUrl) {
        this.avatarUrl = avatarUrl;
    }

    /**
     * 返回实名状态。
     *
     * @return 实名状态（{@code none/pending/passed/rejected}）
     */
    public String getRealnameStatus() {
        return realnameStatus;
    }

    /**
     * 设置实名状态。
     *
     * @param realnameStatus 实名状态
     */
    public void setRealnameStatus(String realnameStatus) {
        this.realnameStatus = realnameStatus;
    }

    /**
     * 返回姓名 AEAD 密文。
     *
     * @return 姓名密文字节（可空）
     */
    public byte[] getRealNameEnc() {
        return realNameEnc;
    }

    /**
     * 设置姓名 AEAD 密文。
     *
     * @param realNameEnc 姓名密文字节
     */
    public void setRealNameEnc(byte[] realNameEnc) {
        this.realNameEnc = realNameEnc;
    }

    /**
     * 返回身份证号盲索引。
     *
     * @return 身份证号 HMAC 盲索引字节（可空）
     */
    public byte[] getIdCardHash() {
        return idCardHash;
    }

    /**
     * 设置身份证号盲索引。
     *
     * @param idCardHash 身份证号 HMAC 盲索引字节
     */
    public void setIdCardHash(byte[] idCardHash) {
        this.idCardHash = idCardHash;
    }

    /**
     * 返回身份证后 4 位明文。
     *
     * @return 身份证后 4 位（可空）
     */
    public String getIdCardLast4() {
        return idCardLast4;
    }

    /**
     * 设置身份证后 4 位明文。
     *
     * @param idCardLast4 身份证后 4 位
     */
    public void setIdCardLast4(String idCardLast4) {
        this.idCardLast4 = idCardLast4;
    }

    /**
     * 返回默认搜索半径档。
     *
     * @return 默认搜索半径档（{@code 1/3/5/10/city}）
     */
    public String getDefaultRadius() {
        return defaultRadius;
    }

    /**
     * 设置默认搜索半径档。
     *
     * @param defaultRadius 默认搜索半径档
     */
    public void setDefaultRadius(String defaultRadius) {
        this.defaultRadius = defaultRadius;
    }

    /**
     * 返回注销发起时间。
     *
     * @return 注销发起时间（可空）
     */
    public LocalDateTime getDeactivateAt() {
        return deactivateAt;
    }

    /**
     * 设置注销发起时间。
     *
     * @param deactivateAt 注销发起时间
     */
    public void setDeactivateAt(LocalDateTime deactivateAt) {
        this.deactivateAt = deactivateAt;
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
     * 返回创建时间。
     *
     * @return 创建时间
     */
    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    /**
     * 设置创建时间。
     *
     * @param createdAt 创建时间
     */
    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }

    /**
     * 返回更新时间。
     *
     * @return 更新时间
     */
    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    /**
     * 设置更新时间。
     *
     * @param updatedAt 更新时间
     */
    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
