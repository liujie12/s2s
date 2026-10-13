package com.s2s.server.ops.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.ops.entity.OpsFollowUpEntity;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 待运营跟进队列 Mapper（映射表 {@code ops_follow_up}；[153] B2-5 ⑥）。
 *
 * <p>写路径用 {@link BaseMapper}；后台列表的**分页查询**用自定义方法——
 * 本工程未注册 MyBatis-Plus 分页插件，故用显式 {@code LIMIT}/{@code OFFSET} 参数绑定
 * （SQL 见 {@code resources/mapper/OpsFollowUpMapper.xml}）。</p>
 *
 * <p><b>为什么必须走 SQL 分页</b>：每有一次「空圈」检索就会入队一条，本表会随
 * 搜索量增长；把它整表拉到内存再切页会随数据量线性劣化后台可用性。</p>
 */
@Mapper
public interface OpsFollowUpMapper extends BaseMapper<OpsFollowUpEntity> {

    /**
     * 统计指定状态的队列条数（后台列表总数）。
     *
     * @param status 处理状态（如 {@code pending}）
     * @return long 命中条数
     */
    long countByStatus(@Param("status") String status);

    /**
     * 按状态分页查询队列（按入队时间升序 = 先来先跟）。
     *
     * @param status 处理状态
     * @param offset 偏移量
     * @param limit  每页条数
     * @return {@link List} 当前页队列条目
     */
    List<OpsFollowUpEntity> selectPageByStatus(@Param("status") String status,
            @Param("offset") int offset, @Param("limit") int limit);
}
