package com.s2s.server.ops.dto;

import com.s2s.server.ops.entity.OpsFollowUpEntity;
import java.util.List;

/**
 * 待运营跟进队列分页结果（[153] B2-5 ⑥；ops 域内部出参）。
 *
 * @param items    当前页条目（按入队时间升序）
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
public record FollowUpPage(
        List<OpsFollowUpEntity> items,
        long total,
        int page,
        int pageSize) {
}
