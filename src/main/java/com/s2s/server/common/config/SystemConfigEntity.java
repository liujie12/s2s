package com.s2s.server.common.config;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 系统级配置实体（[124] 引入，[127] 迁至 common——{@code system_config} 是系统级
 * key-value 配置表（DDL 表注释原文），分类树版本号与详情额度开关等多域共用，
 * 按编码规范 §1.1 上浮公共包，避免 post 域反向依赖 category 域）。
 *
 * <p>职责：承载 {@code system_config} 表一行。字段与 {@code V1__init_schema.sql}
 * 第 116–125 行逐列对齐。</p>
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
