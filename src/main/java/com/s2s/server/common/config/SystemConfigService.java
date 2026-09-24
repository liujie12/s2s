package com.s2s.server.common.config;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.common.config.mapper.SystemConfigMapper;
import org.springframework.stereotype.Service;

/**
 * 系统配置读取服务（[127]；详设 §5.3.4 伪码 {@code configService.isOn(...)} 的落点）。
 *
 * <p>职责：为各域提供 {@code system_config} 的开关/取值读取，使「配置键名 + 真假口径」
 * 单点承载——调用方禁自行拼 {@code QueryWrapper} 或比较字面量 {@code "on"}。</p>
 *
 * <p><b>缺失/读失败一律按「未启用」处理（返回 false）</b>：对称于
 * {@code CategoryService} 配置缺失兜底空串的既有取舍——配置缺失是运维事件，
 * 不该让请求 500。就 {@code detail_quota_enabled} 而言 false 即「额度不生效、放行」，
 * 与 Batch1 开关 off 的既有口径一致（调成 true 反而会把「地图→详情→联系」
 * P0 闭环卡死，见 openapi {@code GET /posts/{id}} 描述）。</p>
 */
@Service
public class SystemConfigService {

    /** 开关类配置的「开」值（DDL 种子 {@code detail_quota_enabled} 用 on/off）。 */
    private static final String VALUE_ON = "on";

    private final SystemConfigMapper systemConfigMapper;

    /**
     * 构造系统配置读取服务。
     *
     * @param systemConfigMapper 系统配置 Mapper
     */
    public SystemConfigService(SystemConfigMapper systemConfigMapper) {
        this.systemConfigMapper = systemConfigMapper;
    }

    /**
     * 读取布尔开关配置。
     *
     * @param configKey 配置键（如 {@code detail_quota_enabled}）
     * @return boolean；配置值为 {@code on}（忽略大小写）时 {@code true}；
     *         配置行缺失、值为 {@code off} 或其他值时 {@code false}
     */
    public boolean isOn(String configKey) {
        String value = getValue(configKey);
        return value != null && VALUE_ON.equalsIgnoreCase(value);
    }

    /**
     * 读取配置值原文。
     *
     * @param configKey 配置键
     * @return {@link String} 配置值；配置行缺失时返回 {@code null}
     */
    public String getValue(String configKey) {
        SystemConfigEntity config = systemConfigMapper.selectOne(
                new QueryWrapper<SystemConfigEntity>().eq("config_key", configKey));
        return config == null ? null : config.getConfigValue();
    }
}
