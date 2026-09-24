package com.s2s.server.category;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.s2s.server.category.dto.CategoryTreeDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.common.config.SystemConfigEntity;
import com.s2s.server.common.config.mapper.SystemConfigMapper;
import java.time.Duration;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link CategoryService} 分类树测试（[124]；详设 §5.2）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>版本一致 → 返回 null（304 语义，HTTP 200 非真 304）；</li>
 *   <li>版本不一致 → 返回全量三级树，sensitive/banned 派生正确；</li>
 *   <li>客户端 version 为 null → 强制全量拉取。</li>
 * </ol>
 *
 * <p>测试策略：Mapper 用 Mockito mock，Caffeine 缓存用真实实例（纯本地无 IO），
 * 聚焦版本协商分支与树构建逻辑。</p>
 */
class CategoryServiceTest {

    private CategoryMapper categoryMapper;
    private SystemConfigMapper systemConfigMapper;
    private CategoryService categoryService;

    /**
     * 每测前置：构造 mock Mapper 与真实缓存，装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        categoryMapper = mock(CategoryMapper.class);
        systemConfigMapper = mock(SystemConfigMapper.class);
        Cache<String, CategoryTreeDto> cache = Caffeine.newBuilder()
                .expireAfterWrite(Duration.ofSeconds(3600))
                .maximumSize(1)
                .build();
        categoryService = new CategoryService(categoryMapper, systemConfigMapper, cache);
    }

    /**
     * 版本一致应返回 null（304 语义）。
     *
     * @return void
     */
    @Test
    void getTree_versionMatch_returnsNull() {
        SystemConfigEntity config = new SystemConfigEntity();
        config.setConfigValue("2026-08-31.1");
        when(systemConfigMapper.selectOne(any())).thenReturn(config);

        CategoryTreeDto result = categoryService.getTree("2026-08-31.1");

        assertThat(result).isNull();
    }

    /**
     * 版本不一致返回全量三级树，sensitive/banned 派生正确。
     *
     * @return void
     */
    @Test
    void getTree_versionMismatch_returnsFullTree() {
        SystemConfigEntity config = new SystemConfigEntity();
        config.setConfigValue("2026-08-31.1");
        when(systemConfigMapper.selectOne(any())).thenReturn(config);

        CategoryEntity l1 = buildCategory(1, null, 1, "工作", "work", null, 0, 1);
        CategoryEntity l2 = buildCategory(101, 1, 2, "全职招聘", null, "enterprise", 0, 1);
        CategoryEntity l3 = buildCategory(10101, 101, 3, "餐饮服务", null, "enterprise", 0, 1);
        when(categoryMapper.selectList(any())).thenReturn(List.of(l1, l2, l3));

        CategoryTreeDto result = categoryService.getTree("old-version");

        assertThat(result).isNotNull();
        assertThat(result.getVersion()).isEqualTo("2026-08-31.1");
        assertThat(result.getCategories()).hasSize(1);
        assertThat(result.getCategories().get(0).getName()).isEqualTo("工作");
        // 二级
        assertThat(result.getCategories().get(0).getChildren()).hasSize(1);
        assertThat(result.getCategories().get(0).getChildren().get(0).getSensitive()).isTrue();
        // 三级
        assertThat(result.getCategories().get(0).getChildren().get(0).getChildren()).hasSize(1);
        // 一级 banned 派生
        assertThat(result.getCategories().get(0).getBanned()).isFalse();
    }

    /**
     * 客户端 version 为 null 强制全量拉取。
     *
     * @return void
     */
    @Test
    void getTree_clientVersionNull_returnsFullTree() {
        SystemConfigEntity config = new SystemConfigEntity();
        config.setConfigValue("2026-08-31.1");
        when(systemConfigMapper.selectOne(any())).thenReturn(config);
        when(categoryMapper.selectList(any())).thenReturn(List.of());

        CategoryTreeDto result = categoryService.getTree(null);

        assertThat(result).isNotNull();
        assertThat(result.getCategories()).isEmpty();
    }

    /**
     * 构造分类实体（减少测试样板）。
     *
     * @param id        分类 ID
     * @param parentId  父 ID（顶级为 null）
     * @param level     层级
     * @param name      名称
     * @param icon      图标
     * @param needCert  认证类型（null = 非高敏）
     * @param forbidden 禁发标记
     * @param sortOrder 排序
     * @return 分类实体
     */
    private CategoryEntity buildCategory(Integer id, Integer parentId, Integer level, String name,
                                         String icon, String needCert, Integer forbidden, Integer sortOrder) {
        CategoryEntity e = new CategoryEntity();
        e.setId(id);
        e.setParentId(parentId);
        e.setLevel(level);
        e.setName(name);
        e.setIcon(icon);
        e.setNeedCert(needCert);
        e.setForbidden(forbidden);
        e.setSortOrder(sortOrder);
        return e;
    }
}
