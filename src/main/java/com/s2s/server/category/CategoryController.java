package com.s2s.server.category;

import com.s2s.server.category.dto.CategoryTreeDto;
import com.s2s.server.category.dto.TemplateDto;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 分类域控制器（[124]；详设 §5.2 category 域接口）。
 *
 * <p>职责：承载 category 域 HTTP 入口：
 * <ul>
 *   <li>{@code GET /categories/tree} — 分类树全量数据（带版本协商）；</li>
 *   <li>{@code GET /templates/{leaf_category_id}} — 叶子类目发布模板。</li>
 * </ul>
 * </p>
 *
 * <p>返回约定：controller 直接返回业务 DTO（或 null），由 {@code ResponseBodyWrapper}
 * 统一套壳 {@code ApiResponse}。{@code /categories/tree} 版本未变时返回 null，
 * 包成 {@code data=null} 表达 304 语义。</p>
 */
@RestController
public class CategoryController {

    private final CategoryService categoryService;
    private final TemplateService templateService;

    /**
     * 构造分类域控制器。
     *
     * @param categoryService 分类树服务
     * @param templateService 模板服务
     */
    public CategoryController(CategoryService categoryService, TemplateService templateService) {
        this.categoryService = categoryService;
        this.templateService = templateService;
    }

    /**
     * 拉取分类树全量数据（带版本协商）。
     *
     * @param version 客户端本地分类树版本号（缺省表示强制全量拉取）
     * @return 版本未变返回 null（304 语义），否则返回全量树
     */
    @GetMapping("/categories/tree")
    public CategoryTreeDto getCategoryTree(
            @RequestParam(value = "version", required = false) String version) {
        return categoryService.getTree(version);
    }

    /**
     * 获取叶子类目的发布模板。
     *
     * @param leafCategoryId 叶子类目 ID（L3）
     * @return 模板 DTO
     */
    @GetMapping("/templates/{leaf_category_id}")
    public TemplateDto getTemplate(@PathVariable("leaf_category_id") Integer leafCategoryId) {
        return templateService.getByLeaf(leafCategoryId);
    }
}
