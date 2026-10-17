package com.s2s.server.category;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.github.benmanes.caffeine.cache.Cache;
import com.s2s.server.category.dto.CategoryNodeDto;
import com.s2s.server.category.dto.CategoryTreeDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
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

    /** 类目层级编号除数：L2 = L3 DIV 100、L1 = L2 DIV 100
     * （与 DDL 生成列 {@code l2_category_id = leaf_category_id DIV 100} 同式）。 */
    private static final int CATEGORY_LEVEL_DIVISOR = 100;

    private final CategoryMapper categoryMapper;
    private final SystemConfigService systemConfigService;
    private final Cache<String, CategoryTreeDto> categoryTreeCache;

    /**
     * 构造分类树服务。
     *
     * @param categoryMapper      分类 Mapper
     * @param systemConfigService 系统配置读取（版本号）
     * @param categoryTreeCache   分类树本地缓存
     */
    public CategoryService(CategoryMapper categoryMapper,
                           SystemConfigService systemConfigService,
                           Cache<String, CategoryTreeDto> categoryTreeCache) {
        this.categoryMapper = categoryMapper;
        this.systemConfigService = systemConfigService;
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
     * 组装叶子类目的面包屑名称（L1 → L2 → L3，[127] 详情页类目显示位）。
     *
     * <p>层级由<b>编号规则</b>直接派生（数据库设计 §7.3：三级类目编号即不变量，
     * 已发布编号不得重排），与 STORED 生成列
     * {@code l2_category_id = leaf_category_id DIV 100} 同式，故无需递归查 parent_id。
     * 一次 {@code selectBatchIds} 取三行走主键，避免三次往返。</p>
     *
     * @param leafCategoryId 叶子类目 ID（L3）；{@code null} 时返回空列表
     * @return {@link List} 名称列表，顺序 L1 → L2 → L3；编号缺级时跳过缺失项
     */
    public List<String> categoryPath(Integer leafCategoryId) {
        if (leafCategoryId == null) {
            return List.of();
        }
        int l2Id = leafCategoryId / CATEGORY_LEVEL_DIVISOR;
        int l1Id = l2Id / CATEGORY_LEVEL_DIVISOR;
        List<CategoryEntity> rows =
                categoryMapper.selectBatchIds(List.of(l1Id, l2Id, leafCategoryId));
        Map<Integer, String> nameById = new HashMap<>();
        for (CategoryEntity row : rows) {
            nameById.put(row.getId(), row.getName());
        }
        List<String> path = new ArrayList<>(3);
        for (int id : new int[] {l1Id, l2Id, leafCategoryId}) {
            String name = nameById.get(id);
            if (name != null) {
                path.add(name);
            }
        }
        return path;
    }

    /**
     * 读取服务端分类树版本号（真源 system_config.category_tree_version）。
     *
     * <p>经 {@link SystemConfigService} 读取而非自行拼 QueryWrapper：配置键名与「缺失
     * 兜底」口径收敛在唯一实现处（编码规范 §1.1/§1.2）。</p>
     *
     * @return 版本号字符串；配置缺失时返回空串
     */
    private String getServerVersion() {
        String value = systemConfigService.getValue(CATEGORY_TREE_VERSION_KEY);
        // 配置缺失兜底：返回空串，客户端必然拉全量
        return value == null ? "" : value;
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
     * 叶子类目选项（B2-4 AI 发布识别用）。
     *
     * <p>把平台三级叶子连同 L1/L2/L3 路径一次性下发到 scope，模型只能从清单中选择，
     * Step 4 按清单校验 —— 属于「平台数据」而非模型编造，不放松严格 Scope 口径。
     * 禁发类目（{@code forbidden=1}）不下发。</p>
     *
     * @return {@link List} 叶子选项（id + 完整路径），按 {@code sort_order} 稳定排序
     */
    public List<LeafOption> listLeafOptions() {
        List<CategoryEntity> all = categoryMapper.selectList(
                new QueryWrapper<CategoryEntity>().orderByAsc("sort_order"));
        Map<Integer, CategoryEntity> byId = new HashMap<>();
        for (CategoryEntity entity : all) {
            byId.put(entity.getId(), entity);
        }
        List<LeafOption> options = new ArrayList<>();
        for (CategoryEntity leaf : all) {
            if (leaf.getLevel() == null || leaf.getLevel() != LEVEL_L3) {
                continue;
            }
            if (leaf.getForbidden() != null && leaf.getForbidden() == 1) {
                continue;
            }
            CategoryEntity l2 = byId.get(leaf.getParentId());
            CategoryEntity l1 = l2 == null ? null : byId.get(l2.getParentId());
            StringBuilder path = new StringBuilder();
            if (l1 != null) {
                path.append(l1.getName()).append(" / ");
            }
            if (l2 != null) {
                path.append(l2.getName()).append(" / ");
            }
            path.append(leaf.getName());
            options.add(new LeafOption(leaf.getId(), path.toString()));
        }
        return options;
    }

    /**
     * 叶子类目选项（AI 识别 scope 的 {@code category_options} 元素）。
     *
     * @param id   叶子类目 ID
     * @param path L1 / L2 / L3 完整路径
     */
    public record LeafOption(int id, String path) {
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

    // ---------------------------------------------------------------------
    // [153] B2-5 ① 分类配置：供后台（admin 域）经 service 接口调用
    // （编码规范 §4.2 域间只调 service，admin 不直连本域 Mapper）
    // ---------------------------------------------------------------------

    /** 分类层级：二级（模板/新增叶子的挂载父级）。 */
    private static final int LEVEL_L2 = 2;

    /** 分类层级：叶子（可发布类目）。 */
    private static final int LEVEL_L3 = 3;

    /** 四级编号：叶子 ID = L2 × 100 + 叶内序号。 */
    private static final int LEAF_ID_FACTOR = 100;

    /**
     * 列出全部分类（后台配置页用，含 {@code forbidden}/{@code need_cert}/{@code sort_order}
     * 等不下发客户端的可配字段）。
     *
     * @return {@link List} 全量分类行，按层级、排序号升序
     */
    public List<CategoryEntity> listAllForAdmin() {
        return categoryMapper.selectList(new QueryWrapper<CategoryEntity>()
                .orderByAsc("level")
                .orderByAsc("sort_order")
                .orderByAsc("id"));
    }

    /**
     * 新增一个叶子类目（PRD §9.10.1 ①「新增/禁用类目（leaf 级）」）。
     *
     * <p>编号自增规则（数据库设计 §7.3 不变量）：叶子 ID = L2 × 100 + 叶内序号，
     * 取该 L2 下现有最大叶子 ID + 1；<b>已发布编号不得重排</b>，故只追加不修改历史号。</p>
     *
     * @param parentL2Id       挂载的二级类目 ID
     * @param name             类目名
     * @param icon             图标名（可空）
     * @param needCert         高敏所需认证类型（可空 = 非高敏）
     * @param forbidden        禁发标记（0/1，可空 = 0）
     * @param sortOrder        同级排序（可空 = 0）
     * @return {@link Integer} 新建叶子类目 ID
     * @throws BizException 父级不存在或非二级 → 40001
     */
    public Integer createLeaf(int parentL2Id, String name, String icon, String needCert,
            Integer forbidden, Integer sortOrder) {
        CategoryEntity parent = categoryMapper.selectById(parentL2Id);
        if (parent == null || parent.getLevel() == null || parent.getLevel() != LEVEL_L2) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        List<CategoryEntity> siblings = categoryMapper.selectList(
                new QueryWrapper<CategoryEntity>().eq("parent_id", parentL2Id));
        int nextSeq = 1;
        for (CategoryEntity sibling : siblings) {
            int seq = sibling.getId() % LEAF_ID_FACTOR;
            nextSeq = Math.max(nextSeq, seq + 1);
        }
        int newId = parentL2Id * LEAF_ID_FACTOR + nextSeq;

        CategoryEntity created = new CategoryEntity();
        created.setId(newId);
        created.setParentId(parentL2Id);
        created.setLevel(LEVEL_L3);
        created.setName(name);
        created.setIcon(icon);
        created.setNeedCert(needCert);
        created.setForbidden(forbidden == null ? 0 : forbidden);
        created.setSortOrder(sortOrder == null ? 0 : sortOrder);
        categoryMapper.insert(created);
        bumpTreeVersion();
        return newId;
    }

    /**
     * 更新类目可配字段（PRD §9.10.1 ①：改名 / 禁用 / 高敏 / 排序 / 图标）。
     *
     * <p>只写非 {@code null} 字段：调用方传 {@code null} 表示「不改该列」，
     * 避免把未提交的列清空。</p>
     *
     * @param id        类目 ID
     * @param name      新名（可空）
     * @param icon      新图标（可空）
     * @param needCert  新高敏认证类型（传 {@code null} 表示不改；本表无「清空」语义）
     * @param forbidden 禁发标记（可空）
     * @param sortOrder 排序号（可空）
     * @throws BizException 类目不存在 → 41001
     */
    public void updateCategory(int id, String name, String icon, String needCert,
            Integer forbidden, Integer sortOrder) {
        CategoryEntity existing = categoryMapper.selectById(id);
        if (existing == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        CategoryEntity patch = new CategoryEntity();
        patch.setId(id);
        patch.setName(name);
        patch.setIcon(icon);
        patch.setNeedCert(needCert);
        patch.setForbidden(forbidden);
        patch.setSortOrder(sortOrder);
        categoryMapper.updateById(patch);
        bumpTreeVersion();
    }

    /**
     * 版本号 +1 并失效分类树缓存（PRD §9.10.1 ①「改完客户端 5 分钟内生效」）。
     *
     * <p>落地口径：分类树客户端按版本协商拉全量（openapi {@code /categories/tree}），
     * 因此「推 JSON 到 CDN」在本工程等价于 <b>bump 版本号 + 失效本地缓存</b>，
     * 客户端下次协商即拉到新树（TTL 兜底）。版本号格式 {@code YYYY-MM-DD.N}，
     * 同日递增 N，跨日重置为 1（字符串比较即可判新旧）。</p>
     */
    private void bumpTreeVersion() {
        String current = getServerVersion();
        String today = java.time.LocalDate.now().toString();
        String next;
        if (current.startsWith(today + ".")) {
            int sequence = Integer.parseInt(current.substring(today.length() + 1)) + 1;
            next = today + "." + sequence;
        } else {
            next = today + ".1";
        }
        systemConfigService.putValue(CATEGORY_TREE_VERSION_KEY, next,
                "分类树版本号（运营改配置时 bump，[153] B2-5 ①）");
        categoryTreeCache.invalidate(CacheConfig.CATEGORY_TREE_CACHE_KEY);
    }
}
