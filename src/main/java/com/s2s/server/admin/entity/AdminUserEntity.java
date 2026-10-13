package com.s2s.server.admin.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 运营治理后台账号实体（映射表 {@code admin_user}；[153] B2-5；DDL {@code V10}）。
 *
 * <p>字段与 DDL {@code V10__admin_user.sql} 逐列对齐。后台账号与 C 端 {@code user}
 * **完全隔离**（《决策登记表》2026-10-12 B2-5 开工批）。</p>
 *
 * <p><b>口令纪律</b>：{@code passwordHash} 只存 PBKDF2 哈希（格式见
 * {@code AdminPasswordHasher}），**禁存明文**；本实体不做哈希，由服务层负责。</p>
 */
@TableName("admin_user")
public class AdminUserEntity {

    /** 管理员 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 登录名（唯一）。 */
    private String username;

    /** 口令哈希（PBKDF2-HMAC-SHA256）。 */
    private String passwordHash;

    /** 后台角色落库值（与 {@code OperatorRole#dbValue()} 逐字一致）。 */
    private String role;

    /** 账号状态：{@code active} / {@code disabled}。 */
    private String status;

    /** 最近登录时刻。 */
    private LocalDateTime lastLoginAt;

    /** 创建时间（库内默认值，服务端不写）。 */
    private LocalDateTime createdAt;

    /** 更新时间（库内 ON UPDATE，服务端不写）。 */
    private LocalDateTime updatedAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public String getUsername() {
        return username;
    }

    public void setUsername(String username) {
        this.username = username;
    }

    public String getPasswordHash() {
        return passwordHash;
    }

    public void setPasswordHash(String passwordHash) {
        this.passwordHash = passwordHash;
    }

    public String getRole() {
        return role;
    }

    public void setRole(String role) {
        this.role = role;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public LocalDateTime getLastLoginAt() {
        return lastLoginAt;
    }

    public void setLastLoginAt(LocalDateTime lastLoginAt) {
        this.lastLoginAt = lastLoginAt;
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
