package com.s2s.server.search.mapper;

import com.s2s.server.search.CategorySynonym;
import java.util.List;

/**
 * 搜索同义词 Mapper（{@code category_synonym} 只读）。
 *
 * <p>注册方式：包名以 {@code .mapper} 结尾，由启动类
 * {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册。</p>
 */
public interface CategorySynonymMapper {

    /**
     * 取全部启用词条（按权重降序，词表规模为百级，可整表加载后内存匹配）。
     *
     * @return {@link List} 启用词条列表（term/pinyin/leafCategoryId/weight）
     */
    List<CategorySynonym> selectAllEnabled();
}
