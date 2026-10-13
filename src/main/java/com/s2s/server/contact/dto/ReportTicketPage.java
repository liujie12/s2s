package com.s2s.server.contact.dto;

import java.util.List;

/**
 * 举报工单分页结果（[153] B2-5 ④；contact 域内部出参）。
 *
 * @param items    当前页工单行
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
public record ReportTicketPage(
        List<ReportTicketRow> items,
        long total,
        int page,
        int pageSize) {
}
