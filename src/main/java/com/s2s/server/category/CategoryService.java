package com.s2s.server.category;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.github.benmanes.caffeine.cache.Cache;
import com.s2s.server.category.dto.CategoryNodeDto;
import com.s2s.server.category.dto.CategoryTreeDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.entity.SystemConfigEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.category.mapper.SystemConfigMapper;
import com.s2s.server.config.CacheConfig;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;

/**
 * 分类树服务（[124]；详设 §5.2）。
 *
 * <p>职责：承载 {@code GET /categories/tree} 的业务逻辑——版本协商与全量树构建。</p>
 *
 * <p>版本协商规则（openapi {@code /categories/tree} description）：
 * <ul>
 *   <li>版本号格式 {@code YYYY-MM-DD.N} 字符串，字符串比较即可判新旧；</li>
 *   <li>客户端传入本地 version，与服务端一致 → 返回 null（HTTP 200，304 语义）；</li>
 *   <li>不一致 → 返回全量树，客户端替换本地数据并清空 Pin 缓存；</li>
 *   <li>版本不一致永不报错、不阻塞、不回 40001。</li>
 * </ul>
 * </p>
 *
 * <p>缓存：全量树走 Caffeine 本地缓存（{@link NfrCache#STATIC_L1_TTL_SEC}），
 * 版本号变化时手动失效（由运营改配置触发，TTL 兜底）。</p>
 */
@Service
public class CategoryService {

    /** system_config 中分类树版本号的键。 */
    private static final String CATEGORY_TREE_VERSION_KEY = "category_tree_version";

    private final CategoryMapper categoryMapper;
    private final SystemConfigMapper systemConfigMapper;
    private final Cache<String, CategoryTreeDto> categoryTreeCache;

    /**
     * 构造分类树服务。
     *
     * @param categoryMapper      分类 Mapper
     * @param systemConfigMapper  系统配置 Mapper
     * @param categoryTreeCache   分类树本地缓存
     */
    public CategoryService(CategoryMapper categoryMapper,
                           SystemConfigMapper systemConfigMapper,
                           Cache<String, CategoryTreeDto> categoryTreeCache) {
        this.categoryMapper = categoryMapper;
        this.systemConfigMapper = systemConfigMapper;
        this.categoryTreeCache = categoryTreeCache;
    }

    /**
     * 获取分类树（带版本协商）。
     *
     * @param clientVersion 客户端本地版本号（null 表示强制全量拉取）
     * @return 版本未变返回 null（304 语义），否则返回全量树
     */
    public CategoryTreeDto getTree(String clientVersion) {
        String serverVersion = getServerVersion();

        // 版本一致 → 304 语义（返回 null，由 controller 包成 data=null）
        if (clientVersion != null && clientVersion.equals(serverVersion)) {
            return null;
        }

        // 版本不一致 → 返回全量树（先查缓存）
        return categoryTreeCache.get(CacheConfig.CATEGORY_TREE_CACHE_KEY, k -> buildTree(serverVersion));
    }

    /**
     * 判断客户端分类树版本是否过期（map 域 {@code /map/pins}、{@code /posts/search}
     * 的 {@code category_version_stale} 判定复用本方法，避免版本比较口径分散）。
     *
     * <p>口径与 {@link #getTree(String)} 一致：版本不一致不报错，仅以布尔值告知，
     * 由客户端异步拉树并清空 Pin 缓存（架构 §9.2.1）。</p>
     *
     * @param clientVersion 客户端本地版本号
     * @return boolean；{@code true} 表示客户端版本过期（含服务端配置缺失兜底空串）
     */
    public boolean isVersionStale(String clientVersion) {
        return !getServerVersion().equals(clientVersion);
    }

    /**
     * 读取服务端分类树版本号（真源 system_config.category_tree_version）。
     *
     * @return 版本号字符串
     */
    private String getServerVersion() {
        SystemConfigEntity config = systemConfigMapper.selectOne(
                new QueryWrapper<SystemConfigEntity>().eq("config_key", CATEGORY_TREE_VERSION_KEY));
        if (config == null) {
            // 配置缺失兜底：返回空串，客户端必然拉全量
            return "";
        }
        return config.getConfigValue();
    }

    /**
     * 从数据库全量构建分类树（三级结构）。
     *
     * @param version 分类树版本号
     * @return 全量分类树 DTO
     */
    private CategoryTreeDto buildTree(String version) {
        List<CategoryEntity> all = categoryMapper.selectList(
                new QueryWrapper<CategoryEntity>().orderByAsc("sort_order"));

        // 按 parent_id 分组
        Map<Integer, List<CategoryEntity>> byParent = new HashMap<>();
        for (CategoryEntity c : all) {
            Integer key = c.getParentId() == null ? 0 : c.getParentId();
            byParent.computeIfAbsent(key, k -> new ArrayList<>()).add(c);
        }

        // 构建一级 → 二级 → 三级
        List<CategoryNodeDto> roots = new ArrayList<>();
        for (CategoryEntity l1 : byParent.getOrDefault(0, List.of())) {
            List<CategoryNodeDto> l2Nodes = new ArrayList<>();
            for (CategoryEntity l2 : byParent.getOrDefault(l1.getId(), List.of())) {
                List<CategoryNodeDto> l3Nodes = new ArrayList<>();
                for (CategoryEntity l3 : byParent.getOrDefault(l2.getId(), List.of())) {
                    l3Nodes.add(toDto(l3, null));
                }
                l2Nodes.add(toDto(l2, l3Nodes));
            }
            roots.add(toDto(l1, l2Nodes));
        }

        // 一级按 id 排序（sort_order 已排，但分组后保持插入序，id 排序确保稳定）
        roots.sort(Comparator.comparing(CategoryNodeDto::getId));
        return new CategoryTreeDto(version, roots);
    }

    /**
     * 将实体转为 DTO（含 sensitive/banned 派生）。
     *
     * @param entity   分类实体
     * @param children 子节点列表（L3 为 null）
     * @return 分类节点 DTO
     */
    private CategoryNodeDto toDto(CategoryEntity entity, List<CategoryNodeDto> children) {
        return new CategoryNodeDto(
                entity.getId(),
                entity.getName(),
                entity.getLevel(),
                entity.getIcon(),
                entity.getNeedCert() != null,   // need_cert 非空 → 高敏
                entity.getForbidden() != null && entity.getForbidden() != 0,  // forbidden != 0 → 禁发
                children
        );
    }
}
