package com.s2s.server.category.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 发布模板 DTO（对齐 openapi {@code Template} schema）。
 *
 * <p>叶子类目发布模板，驱动客户端动态表单渲染。</p>
 */
public class TemplateDto {

    /** 叶子类目 ID（L3）。 */
    private Integer leafCategoryId;

    /** 模板字段列表。 */
    private List<TemplateFieldDto> fields;

    public TemplateDto() {
    }

    public TemplateDto(Integer leafCategoryId, List<TemplateFieldDto> fields) {
        this.leafCategoryId = leafCategoryId;
        this.fields = fields;
    }

    @JsonProperty("leaf_category_id")
    public Integer getLeafCategoryId() {
        return leafCategoryId;
    }

    public void setLeafCategoryId(Integer leafCategoryId) {
        this.leafCategoryId = leafCategoryId;
    }

    @JsonProperty("fields")
    public List<TemplateFieldDto> getFields() {
        return fields;
    }

    public void setFields(List<TemplateFieldDto> fields) {
        this.fields = fields;
    }
}
