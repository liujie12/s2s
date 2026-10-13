package com.s2s.server.common.audit.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 审计查询分页出参（[153] B2-5）。
 *
 * @param items    当前页条目（按操作时间倒序）
 * @param total    命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AuditLogPage(
        List<AuditLogItem> items,
        long total,
        int page,
        int pageSize) {
}
