package com.s2s.server.category;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.benmanes.caffeine.cache.Cache;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.dto.TemplateFieldDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.entity.TemplateEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.category.mapper.TemplateMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 发布模板服务（[124]；详设 §5.2）。
 *
 * <p>职责：承载 {@code GET /templates/{leaf_category_id}} 的业务逻辑。</p>
 *
 * <p>核心规则（openapi description）：
 * <ul>
 *   <li>叶子类目不存在（category 表无 level=3 对应行）→ 40001；</li>
 *   <li>叶子存在但 template 表无对应行 → 返回通用模板（fallback）；</li>
 *   <li>模板按 L2 父级存储（对齐前端 templateForLeaf 的 leafCategoryId ~/ 100）。</li>
 * </ul>
 * </p>
 *
 * <p>缓存：模板走 Caffeine 本地缓存（{@link NfrCache#STATIC_L1_TTL_SEC}）。</p>
 */
@Service
public class TemplateService {

    private final CategoryMapper categoryMapper;
    private final TemplateMapper templateMapper;
    private final Cache<Integer, TemplateDto> templateCache;
    private final ObjectMapper objectMapper;

    /**
     * 构造模板服务。
     *
     * @param categoryMapper 分类 Mapper（校验叶子是否存在）
     * @param templateMapper 模板 Mapper
     * @param templateCache  模板本地缓存
     * @param objectMapper   JSON 反序列化器
     */
    public TemplateService(CategoryMapper categoryMapper,
                           TemplateMapper templateMapper,
                           Cache<Integer, TemplateDto> templateCache,
                           ObjectMapper objectMapper) {
        this.categoryMapper = categoryMapper;
        this.templateMapper = templateMapper;
        this.templateCache = templateCache;
        this.objectMapper = objectMapper;
    }

    /**
     * 获取叶子类目的发布模板。
     *
     * @param leafCategoryId 叶子类目 ID（L3）
     * @return 模板 DTO
     * @throws BizException 叶子不存在 → 40001
     */
    public TemplateDto getByLeaf(Integer leafCategoryId) {
        // 1. 校验叶子是否存在（level=3）
        CategoryEntity leaf = categoryMapper.selectOne(
                new QueryWrapper<CategoryEntity>()
                        .eq("id", leafCategoryId)
                        .eq("level", 3));
        if (leaf == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        // 2. 查缓存
        return templateCache.get(leafCategoryId, this::loadTemplate);
    }

    /**
     * 从数据库加载模板（缓存未命中时调用）。
     *
     * <p>查找口径（对齐前端 {@code templateForLeaf} 的 {@code leafCategoryId ~/ 100}）：
     * 模板按 <b>L2 父级</b> 存储（{@code template.leaf_category_id} 存的是 L2 ID），
     * 同一 L2 下所有叶子共享一份模板。先取叶子的 {@code parent_id}，再据此查模板表。</p>
     *
     * @param leafCategoryId 叶子类目 ID
     * @return 模板 DTO
     */
    private TemplateDto loadTemplate(Integer leafCategoryId) {
        // 取叶子的 L2 父级 ID
        CategoryEntity leaf = categoryMapper.selectById(leafCategoryId);
        Integer parentId = (leaf != null) ? leaf.getParentId() : null;

        if (parentId != null) {
            TemplateEntity entity = templateMapper.selectOne(
                    new QueryWrapper<TemplateEntity>().eq("leaf_category_id", parentId));
            if (entity != null && entity.getFields() != null) {
                return parseTemplate(leafCategoryId, entity.getFields());
            }
        }

        // 无自定义模板 → 返回通用模板
        return buildGenericTemplate(leafCategoryId);
    }

    /**
     * 解析 template.fields JSON 为 DTO。
     *
     * @param leafCategoryId 叶子类目 ID
     * @param fieldsJson     fields 列 JSON
     * @return 模板 DTO
     */
    private TemplateDto parseTemplate(Integer leafCategoryId, String fieldsJson) {
        try {
            List<TemplateFieldDto> fields = objectMapper.readValue(
                    fieldsJson, new TypeReference<List<TemplateFieldDto>>() {});
            return new TemplateDto(leafCategoryId, fields);
        } catch (Exception e) {
            // JSON 解析失败兜底为通用模板（不阻塞发布）
            return buildGenericTemplate(leafCategoryId);
        }
    }

    /**
     * 构建通用模板（无自定义模板时的 fallback）。
     *
     * <p>包含发布的最小必填字段集，确保所有叶子类目至少有可发布的表单结构。</p>
     *
     * @param leafCategoryId 叶子类目 ID
     * @return 通用模板 DTO
     */
    private TemplateDto buildGenericTemplate(Integer leafCategoryId) {
        return new TemplateDto(leafCategoryId, List.of(
                new TemplateFieldDto("description", "描述", "text", true, null, null, "请输入详细描述"),
                new TemplateFieldDto("price", "价格", "number", false, null, null, "面议可不填")
        ));
    }
}
