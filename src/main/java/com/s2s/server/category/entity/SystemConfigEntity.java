package com.s2s.server.category.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 系统级配置实体（[124]；映射表 {@code system_config}）。
 *
 * <p>职责：承载 {@code system_config} 表一行，承载分类树全局版本号等系统级配置。
 * 字段与 {@code V1__init_schema.sql} 第 116–125 行逐列对齐。</p>
 *
 * <p>分类树版本号真源为 {@code config_key='category_tree_version'} 的行，
 * 值格式为 {@code YYYY-MM-DD.N} 字符串（架构 §9.2.1 唯一口径）。</p>
 */
@TableName("system_config")
public class SystemConfigEntity {

    /** 配置项 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 配置键（如 category_tree_version）。 */
    private String configKey;

    /** 配置值。 */
    private String configValue;

    /** 配置说明。 */
    private String description;

    /** 更新时间。 */
    private LocalDateTime updatedAt;

    /** 乐观锁版本号。 */
    private Integer version;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public String getConfigKey() {
        return configKey;
    }

    public void setConfigKey(String configKey) {
        this.configKey = configKey;
    }

    public String getConfigValue() {
        return configValue;
    }

    public void setConfigValue(String configValue) {
        this.configValue = configValue;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }

    public Integer getVersion() {
        return version;
    }

    public void setVersion(Integer version) {
        this.version = version;
    }
}
