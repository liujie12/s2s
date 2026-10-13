package com.s2s.server.cert.dto;

import com.s2s.server.cert.entity.CertEntity;
import java.util.List;

/**
 * 认证审核队列分页结果（[153] B2-5 ⑤；cert 域内部出参，供 admin 域映射）。
 *
 * @param items    当前页认证记录（按提交时间升序）
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
public record CertReviewPage(
        List<CertEntity> items,
        long total,
        int page,
        int pageSize) {
}
