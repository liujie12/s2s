package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 后台账号列表出参（[153] B2-5；PRD §9.10.1「账号与角色管理」为超管职责）。
 *
 * @param items 全部后台账号（按 ID 升序）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminAccountListResponse(List<Item> items) {

    /**
     * 账号条目（**不含口令哈希**）。
     *
     * @param id          管理员 ID
     * @param username    登录名
     * @param role        角色落库值
     * @param status      账号状态 active/disabled
     * @param lastLoginAt 最近登录时刻
     * @param createdAt   创建时间
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Long id,
            String username,
            String role,
            String status,
            Instant lastLoginAt,
            Instant createdAt) {
    }
}
