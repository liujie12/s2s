package com.s2s.server.category.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 分类树全量数据 DTO（对齐 openapi {@code CategoryTree} schema）。
 *
 * <p>包含全局版本号与一级类目列表。版本号格式 {@code YYYY-MM-DD.N} 字符串。</p>
 */
public class CategoryTreeDto {

    /** 分类树全局版本号（真源 system_config.category_tree_version）。 */
    private String version;

    /** 一级类目列表。 */
    private List<CategoryNodeDto> categories;

    public CategoryTreeDto() {
    }

    public CategoryTreeDto(String version, List<CategoryNodeDto> categories) {
        this.version = version;
        this.categories = categories;
    }

    @JsonProperty("version")
    public String getVersion() {
        return version;
    }

    public void setVersion(String version) {
        this.version = version;
    }

    @JsonProperty("categories")
    public List<CategoryNodeDto> getCategories() {
        return categories;
    }

    public void setCategories(List<CategoryNodeDto> categories) {
        this.categories = categories;
    }
}
