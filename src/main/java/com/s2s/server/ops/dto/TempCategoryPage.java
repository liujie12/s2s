package com.s2s.server.ops.dto;

import java.util.List;

/**
 * 临时类目分页结果（[153] B2-5 §9.10.2；ops 域内部出参）。
 *
 * @param items    当前页视图（按创建时间倒序）
 * @param total    命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
public record TempCategoryPage(
        List<TempCategoryView> items,
        long total,
        int page,
        int pageSize) {
}
