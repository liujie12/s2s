package com.s2s.server.cert.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.cert.entity.CertEntity;
import java.util.List;
import org.apache.ibatis.annotations.Param;

/**
 * {@code cert} 表数据访问接口（[149] 建立；[153] B2-5 增审核队列分页查询）。
 *
 * <p>职责：为 {@link CertEntity} 提供 MyBatis-Plus 基础 CRUD；审核队列的**分页查询**
 * 用自定义方法（本工程未注册 MyBatis-Plus 分页插件，{@code selectPage} 会静默不分页，
 * 故用显式 {@code LIMIT}/{@code OFFSET} 参数绑定，SQL 见 {@code resources/mapper/CertMapper.xml}）。</p>
 *
 * <p>注册方式：由启动类 {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册。</p>
 *
 * <p>域边界（编码规范 §4.2）：仅 cert 域内 service 可注入本接口；后台（admin 域）
 * 经 {@code CertService} 的 service 接口取数，不直连本 Mapper。</p>
 */
public interface CertMapper extends BaseMapper<CertEntity> {

    /**
     * 统计指定状态的认证条数（审核队列总数）。
     *
     * @param status 认证状态（如 {@code pending}）
     * @return long 命中条数
     */
    long countByStatus(@Param("status") String status);

    /**
     * 按状态分页查询认证记录（按提交时间升序，对齐 PRD §9.10.1「队列按提交时间排序」）。
     *
     * @param status 认证状态
     * @param offset 偏移量
     * @param limit  每页条数
     * @return {@link List} 当前页认证记录
     */
    List<CertEntity> selectPageByStatus(@Param("status") String status,
            @Param("offset") int offset, @Param("limit") int limit);
}
