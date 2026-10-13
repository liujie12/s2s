package com.s2s.server.ops.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.ops.entity.TempCategoryEntity;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 72h 临时类目 Mapper（映射表 {@code temp_category}；[153] B2-5 §9.10.2）。
 *
 * <p>写路径（创建 / 到期结算改状态）用 {@link BaseMapper}；后台列表的**分页查询**
 * 用自定义方法——本工程未注册 MyBatis-Plus 分页插件，故用显式 {@code LIMIT}/{@code OFFSET}
 * 参数绑定（SQL 见 {@code resources/mapper/TempCategoryMapper.xml}），与
 * {@code OpsFollowUpMapper} 同范式。</p>
 */
@Mapper
public interface TempCategoryMapper extends BaseMapper<TempCategoryEntity> {

    /**
     * 统计指定状态的临时类目条数（后台列表总数）。
     *
     * @param status 生命周期状态（{@code null}/空 → 不限，统计全部）
     * @return long 命中条数
     */
    long countByStatus(@Param("status") String status);

    /**
     * 按状态分页查询临时类目（按创建时间倒序 = 最新创建的排前）。
     *
     * @param status 生命周期状态（{@code null}/空 → 不限）
     * @param offset 偏移量
     * @param limit  每页条数
     * @return {@link List} 当前页临时类目
     */
    List<TempCategoryEntity> selectPageByStatus(@Param("status") String status,
            @Param("offset") int offset, @Param("limit") int limit);
}
