package com.s2s.server.category;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.entity.TemplateEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.category.mapper.TemplateMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.Duration;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link TemplateService} 发布模板测试（[124]；详设 §5.2）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>叶子不存在 → 40001（{@link ErrorCode#PARAM_INVALID}）；</li>
 *   <li>自定义模板命中（按 L2 父级查）→ 返回字段；</li>
 *   <li>无自定义模板 → 返回通用模板兜底（含 description 字段）。</li>
 * </ol>
 *
 * <p>测试策略：Mapper 用 Mockito mock，ObjectMapper/Caffeine 用真实实例。</p>
 */
class TemplateServiceTest {

    private CategoryMapper categoryMapper;
    private TemplateMapper templateMapper;
    private TemplateService templateService;

    /**
     * 每测前置：构造 mock Mapper 与真实缓存/ObjectMapper，装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        categoryMapper = mock(CategoryMapper.class);
        templateMapper = mock(TemplateMapper.class);
        Cache<Integer, TemplateDto> cache = Caffeine.newBuilder()
                .expireAfterWrite(Duration.ofSeconds(3600))
                .maximumSize(64)
                .build();
        templateService = new TemplateService(categoryMapper, templateMapper, cache, new ObjectMapper());
    }

    /**
     * 叶子不存在抛 40001。
     *
     * @return void
     */
    @Test
    void getByLeaf_leafNotExists_throws40001() {
        when(categoryMapper.selectOne(any())).thenReturn(null);

        assertThatThrownBy(() -> templateService.getByLeaf(99999))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 自定义模板命中（按 L2 父级查），返回字段。
     *
     * @return void
     */
    @Test
    void getByLeaf_customTemplateFound_returnsFields() {
        CategoryEntity leaf = new CategoryEntity();
        leaf.setId(10101);
        leaf.setParentId(101);
        leaf.setLevel(3);
        when(categoryMapper.selectOne(any())).thenReturn(leaf);
        when(categoryMapper.selectById(10101)).thenReturn(leaf);

        TemplateEntity tpl = new TemplateEntity();
        tpl.setLeafCategoryId(101);
        tpl.setFields("[{\"key\":\"headcount\",\"label\":\"招聘人数\",\"type\":\"number\",\"required\":true}]");
        when(templateMapper.selectOne(any())).thenReturn(tpl);

        TemplateDto result = templateService.getByLeaf(10101);

        assertThat(result).isNotNull();
        assertThat(result.getLeafCategoryId()).isEqualTo(10101);
        assertThat(result.getFields()).hasSize(1);
        assertThat(result.getFields().get(0).getKey()).isEqualTo("headcount");
    }

    /**
     * 无自定义模板返回通用模板兜底（含 description 字段）。
     *
     * @return void
     */
    @Test
    void getByLeaf_noCustomTemplate_returnsGeneric() {
        CategoryEntity leaf = new CategoryEntity();
        leaf.setId(20101);
        leaf.setParentId(201);
        leaf.setLevel(3);
        when(categoryMapper.selectOne(any())).thenReturn(leaf);
        when(categoryMapper.selectById(20101)).thenReturn(leaf);
        when(templateMapper.selectOne(any())).thenReturn(null);

        TemplateDto result = templateService.getByLeaf(20101);

        assertThat(result).isNotNull();
        assertThat(result.getLeafCategoryId()).isEqualTo(20101);
        assertThat(result.getFields())
                .anySatisfy(f -> assertThat(f.getKey()).isEqualTo("description"));
    }
}
