package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 分类配置列表出参（[153] B2-5 ①；PRD §9.10.1 ①）。
 *
 * <p>后台视角，含不下发客户端的可配字段（{@code forbidden}/{@code need_cert}/
 * {@code sort_order}/{@code cluster_threshold}）。</p>
 *
 * @param items 全量分类行（按层级、排序号、ID 升序）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCategoryListResponse(List<Item> items) {

    /**
     * 分类条目。
     *
     * @param id               类目 ID（即层级编号）
     * @param parentId         父类目 ID（顶级为 null）
     * @param level            层级 1/2/3
     * @param name             类目名
     * @param icon             图标名
     * @param needCert         高敏所需认证类型（null = 非高敏）
     * @param forbidden        禁发标记（0/1）
     * @param sortOrder        同级排序
     * @param clusterThreshold 差异化聚合阈值
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Integer id,
            Integer parentId,
            Integer level,
            String name,
            String icon,
            String needCert,
            Integer forbidden,
            Integer sortOrder,
            Integer clusterThreshold) {
    }
}
