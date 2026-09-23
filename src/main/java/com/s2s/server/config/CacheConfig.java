package com.s2s.server.config;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.s2s.server.category.dto.CategoryTreeDto;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.common.constants.NfrCache;
import java.time.Duration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 本地缓存配置（[124]；详设 §5.2）。
 *
 * <p>分类树与模板属静态数据，走 {@link NfrCache#STATIC_L1_TTL_SEC} 档本地 Caffeine 缓存。
 * 配置变更后传播延迟上限见 {@link NfrCache#CONFIG_PROPAGATE_SEC}。</p>
 *
 * <p>两个缓存 Bean：
 * <ul>
 *   <li>{@code categoryTreeCache}：key 固定为 {@code "tree"}，value 为全量分类树；</li>
 *   <li>{@code templateCache}：key 为 leaf_category_id，value 为模板。</li>
 * </ul>
 * </p>
 */
@Configuration
public class CacheConfig {

    /** 分类树缓存键（单例，全树只有一份）。 */
    public static final String CATEGORY_TREE_CACHE_KEY = "tree";

    /**
     * 分类树全量缓存。
     *
     * @return Caffeine 缓存实例，TTL = {@link NfrCache#STATIC_L1_TTL_SEC} 秒
     */
    @Bean
    public Cache<String, CategoryTreeDto> categoryTreeCache() {
        return Caffeine.newBuilder()
                .expireAfterWrite(Duration.ofSeconds(NfrCache.STATIC_L1_TTL_SEC))
                .maximumSize(1)
                .build();
    }

    /**
     * 叶子类目模板缓存。
     *
     * @return Caffeine 缓存实例，TTL = {@link NfrCache#STATIC_L1_TTL_SEC} 秒
     */
    @Bean
    public Cache<Integer, TemplateDto> templateCache() {
        return Caffeine.newBuilder()
                .expireAfterWrite(Duration.ofSeconds(NfrCache.STATIC_L1_TTL_SEC))
                .maximumSize(64)
                .build();
    }
}
