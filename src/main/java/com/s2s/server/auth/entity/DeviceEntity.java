package com.s2s.server.auth.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 设备实体（[123] U2；映射表 {@code device}）。
 *
 * <p>职责：承载 {@code device} 表一行，是「推送 token 与设备指纹」双重职责的持久层载体
 * ——{@code fingerprint} 做联系限频的设备维（PRD §7.7），{@code push_token} 做推送下发
 * （架构 §2）。字段与 {@code V1__init_schema.sql} 第 352–363 行<b>逐列</b>对齐。</p>
 *
 * <p>语义约束：{@code fingerprint} 唯一（{@code uk_fingerprint}），重装即变（新指纹 = 新行）；
 * {@code platform} 为 {@code android/ios} 二选一；{@code push_token} 可空（未授权推送时）。</p>
 *
 * <p>类型映射：{@code ENUM} → {@link String}（U2 决策）；{@code BIGINT} → {@link Long}；
 * {@code VARCHAR} → {@link String}；{@code DATETIME} → {@link LocalDateTime}。</p>
 *
 * <p>出处：详设 §13.2（R21）、数据库设计文档 §5.1、PRD §7.7（限频设备维）。</p>
 */
@TableName("device")
public class DeviceEntity {

    /** 设备 ID（主键，数据库 AUTO_INCREMENT 自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 所属 user.id。 */
    private Long userId;

    /** 设备指纹（UUID，限频键，重装即变）。 */
    private String fingerprint;

    /** 平台：{@code android/ios}。 */
    private String platform;

    /** 推送 token（FCM/APNs，可空）。 */
    private String pushToken;

    /** 最后活跃时间（数据库默认 CURRENT_TIMESTAMP）。 */
    private LocalDateTime lastActiveAt;

    /**
     * 返回设备 ID。
     *
     * @return 设备 ID（主键）
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置设备 ID。
     *
     * @param id 设备 ID
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
     * 返回设备指纹。
     *
     * @return 设备指纹
     */
    public String getFingerprint() {
        return fingerprint;
    }

    /**
     * 设置设备指纹。
     *
     * @param fingerprint 设备指纹
     */
    public void setFingerprint(String fingerprint) {
        this.fingerprint = fingerprint;
    }

    /**
     * 返回平台。
     *
     * @return 平台（{@code android/ios}）
     */
    public String getPlatform() {
        return platform;
    }

    /**
     * 设置平台。
     *
     * @param platform 平台
     */
    public void setPlatform(String platform) {
        this.platform = platform;
    }

    /**
     * 返回推送 token。
     *
     * @return 推送 token（可空）
     */
    public String getPushToken() {
        return pushToken;
    }

    /**
     * 设置推送 token。
     *
     * @param pushToken 推送 token
     */
    public void setPushToken(String pushToken) {
        this.pushToken = pushToken;
    }

    /**
     * 返回最后活跃时间。
     *
     * @return 最后活跃时间
     */
    public LocalDateTime getLastActiveAt() {
        return lastActiveAt;
    }

    /**
     * 设置最后活跃时间。
     *
     * @param lastActiveAt 最后活跃时间
     */
    public void setLastActiveAt(LocalDateTime lastActiveAt) {
        this.lastActiveAt = lastActiveAt;
    }
}
