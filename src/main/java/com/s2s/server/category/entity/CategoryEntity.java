package com.s2s.server.category.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;

/**
 * 三级分类树实体（[124]；映射表 {@code category}）。
 *
 * <p>职责：承载 {@code category} 表一行，是 category 域「分类树查询」的持久层载体。
 * 字段与 {@code V1__init_schema.sql} 第 80–94 行<b>逐列</b>对齐。</p>
 *
 * <p>编号不变量：{@code id} 即层级编号（一级 N / 二级 N*100+M / 三级 N*10000+M*100+K），
 * 已发布的编号不得重排（{@code lib/domain/category_tree.dart} 真源）。</p>
 *
 * <p>列口径映射：
 * <ul>
 *   <li>{@code need_cert} 非 NULL → 高敏类目（API {@code sensitive=true}）；</li>
 *   <li>{@code forbidden != 0} → 禁发类目（API {@code banned=true}）；</li>
 *   <li>{@code color} / {@code cluster_threshold} 仅服务端使用，不下发客户端。</li>
 * </ul>
 * </p>
 */
@TableName("category")
public class CategoryEntity {

    /** 分类 ID（主键，即层级编号，非自增）。 */
    @TableId(value = "id", type = IdType.INPUT)
    private Integer id;

    /** 父分类 ID；顶级为 NULL。 */
    private Integer parentId;

    /** 层级：1=大类 / 2=二级 / 3=叶子。 */
    private Integer level;

    /** 分类名。 */
    private String name;

    /** 大类色 Token 键（如 cat-vehicle），仅一级行有值。 */
    private String color;

    /** Material Symbols 图标名。 */
    private String icon;

    /** 非 NULL 即高敏类目，发布前强制认证类型（personal_qualification/enterprise/vehicle）。 */
    private String needCert;

    /** 禁发类目标记（0=可发 / 1=禁发）。 */
    private Integer forbidden;

    /** 差异化聚合阈值（仅一级行显式，二级/三级取列默认 8）。 */
    private Integer clusterThreshold;

    /** 同级排序。 */
    private Integer sortOrder;

    public Integer getId() {
        return id;
    }

    public void setId(Integer id) {
        this.id = id;
    }

    public Integer getParentId() {
        return parentId;
    }

    public void setParentId(Integer parentId) {
        this.parentId = parentId;
    }

    public Integer getLevel() {
        return level;
    }

    public void setLevel(Integer level) {
        this.level = level;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getColor() {
        return color;
    }

    public void setColor(String color) {
        this.color = color;
    }

    public String getIcon() {
        return icon;
    }

    public void setIcon(String icon) {
        this.icon = icon;
    }

    public String getNeedCert() {
        return needCert;
    }

    public void setNeedCert(String needCert) {
        this.needCert = needCert;
    }

    public Integer getForbidden() {
        return forbidden;
    }

    public void setForbidden(Integer forbidden) {
        this.forbidden = forbidden;
    }

    public Integer getClusterThreshold() {
        return clusterThreshold;
    }

    public void setClusterThreshold(Integer clusterThreshold) {
        this.clusterThreshold = clusterThreshold;
    }

    public Integer getSortOrder() {
        return sortOrder;
    }

    public void setSortOrder(Integer sortOrder) {
        this.sortOrder = sortOrder;
    }
}
