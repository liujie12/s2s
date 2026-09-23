package com.s2s.server.category.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 分类节点 DTO（对齐 openapi {@code CategoryNode} schema）。
 *
 * <p>三级结构 L1 → L2 → L3（叶子），{@code children} 在 L3 为 null。</p>
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public class CategoryNodeDto {

    /** 类目 ID。L3 与 L2 满足 l2_id = l3_id DIV 100。 */
    private Integer id;

    /** 类目名。 */
    private String name;

    /** 层级：1 / 2 / 3。 */
    private Integer level;

    /** Material Symbols 图标名（可空）。 */
    private String icon;

    /** true 表示高敏类目，发布需先通过资质认证。 */
    private Boolean sensitive;

    /** true 表示当前禁止发布。 */
    private Boolean banned;

    /** 子节点。L3 无 children。 */
    private List<CategoryNodeDto> children;

    public CategoryNodeDto() {
    }

    public CategoryNodeDto(Integer id, String name, Integer level, String icon,
                           Boolean sensitive, Boolean banned, List<CategoryNodeDto> children) {
        this.id = id;
        this.name = name;
        this.level = level;
        this.icon = icon;
        this.sensitive = sensitive;
        this.banned = banned;
        this.children = children;
    }

    @JsonProperty("id")
    public Integer getId() {
        return id;
    }

    public void setId(Integer id) {
        this.id = id;
    }

    @JsonProperty("name")
    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    @JsonProperty("level")
    public Integer getLevel() {
        return level;
    }

    public void setLevel(Integer level) {
        this.level = level;
    }

    @JsonProperty("icon")
    public String getIcon() {
        return icon;
    }

    public void setIcon(String icon) {
        this.icon = icon;
    }

    @JsonProperty("sensitive")
    public Boolean getSensitive() {
        return sensitive;
    }

    public void setSensitive(Boolean sensitive) {
        this.sensitive = sensitive;
    }

    @JsonProperty("banned")
    public Boolean getBanned() {
        return banned;
    }

    public void setBanned(Boolean banned) {
        this.banned = banned;
    }

    @JsonProperty("children")
    public List<CategoryNodeDto> getChildren() {
        return children;
    }

    public void setChildren(List<CategoryNodeDto> children) {
        this.children = children;
    }
}
