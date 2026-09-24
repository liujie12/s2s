package com.s2s.server.category.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 叶子类目发布模板实体（[124]；映射表 {@code template}）。
 *
 * <p>职责：承载 {@code template} 表一行，是模板查询的持久层载体。
 * 字段与 {@code V1__init_schema.sql} 第 101–109 行逐列对齐。</p>
 *
 * <p>{@code fields} 列为 JSON，存储动态表单 Schema（字段定义、校验规则等），
 * 与 {@code post.template_version} 对齐用于发布时取对应版本模板。</p>
 */
@TableName("template")
public class TemplateEntity {

    /** 模板 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 叶子类目 ID（与 category 表 1:1）。 */
    private Integer leafCategoryId;

    /** 动态表单 Schema JSON。 */
    private String fields;

    /** 模板版本号，与 post.template_version 对齐。 */
    private Integer templateVersion;

    /** 模板更新时间。 */
    private LocalDateTime updatedAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Integer getLeafCategoryId() {
        return leafCategoryId;
    }

    public void setLeafCategoryId(Integer leafCategoryId) {
        this.leafCategoryId = leafCategoryId;
    }

    public String getFields() {
        return fields;
    }

    public void setFields(String fields) {
        this.fields = fields;
    }

    public Integer getTemplateVersion() {
        return templateVersion;
    }

    public void setTemplateVersion(Integer templateVersion) {
        this.templateVersion = templateVersion;
    }

    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
