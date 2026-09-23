package com.s2s.server.category.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 模板字段 DTO（对齐 openapi {@code TemplateField} schema）。
 *
 * <p>驱动客户端动态表单渲染。{@code required} 标记同时是
 * {@code post.attributes} 完整度判定（{@code required_full}）的依据。</p>
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public class TemplateFieldDto {

    /** 字段键，落 post.attributes JSON 的一级键。 */
    private String key;

    /** 字段标签。 */
    private String label;

    /** 字段类型：text / number / select / multi_select / date。 */
    private String type;

    /** 是否必填。全部 required 填齐即 required_full=true。 */
    private Boolean required;

    /** 仅 select / multi_select 有值。 */
    private List<String> options;

    /** 单位（可空）。 */
    private String unit;

    /** 占位提示（可空）。 */
    private String placeholder;

    public TemplateFieldDto() {
    }

    public TemplateFieldDto(String key, String label, String type, Boolean required,
                            List<String> options, String unit, String placeholder) {
        this.key = key;
        this.label = label;
        this.type = type;
        this.required = required;
        this.options = options;
        this.unit = unit;
        this.placeholder = placeholder;
    }

    @JsonProperty("key")
    public String getKey() {
        return key;
    }

    public void setKey(String key) {
        this.key = key;
    }

    @JsonProperty("label")
    public String getLabel() {
        return label;
    }

    public void setLabel(String label) {
        this.label = label;
    }

    @JsonProperty("type")
    public String getType() {
        return type;
    }

    public void setType(String type) {
        this.type = type;
    }

    @JsonProperty("required")
    public Boolean getRequired() {
        return required;
    }

    public void setRequired(Boolean required) {
        this.required = required;
    }

    @JsonProperty("options")
    public List<String> getOptions() {
        return options;
    }

    public void setOptions(List<String> options) {
        this.options = options;
    }

    @JsonProperty("unit")
    public String getUnit() {
        return unit;
    }

    public void setUnit(String unit) {
        this.unit = unit;
    }

    @JsonProperty("placeholder")
    public String getPlaceholder() {
        return placeholder;
    }

    public void setPlaceholder(String placeholder) {
        this.placeholder = placeholder;
    }
}
