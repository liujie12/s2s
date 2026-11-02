package com.s2s.server.contact.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.contact.dto.ReportDetailRow;
import com.s2s.server.contact.dto.ReportTicketRow;
import com.s2s.server.contact.entity.ReportEntity;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 举报 Mapper（映射表 {@code report}）。
 *
 * <p>Batch1 只有「新增举报」一条写路径（{@link BaseMapper} 即可）；[153] B2-5 ④
 * 增后台工单队列的**分页查询**（联 {@code post} 取累计风险分，按风险分降序）——
 * 本工程未注册 MyBatis-Plus 分页插件，故用显式 {@code LIMIT}/{@code OFFSET} 参数绑定，
 * SQL 见 {@code resources/mapper/ReportMapper.xml}。</p>
 */
@Mapper
public interface ReportMapper extends BaseMapper<ReportEntity> {

    /**
     * 统计指定状态（可再按原因筛选）的举报条数（工单队列总数）。
     *
     * @param status 工单状态（如 {@code pending}）
     * @param reason 举报原因筛选（可空=不筛；传 {@code misblock} 即误拦反馈专属队列）
     * @return long 命中条数
     */
    long countByStatus(@Param("status") String status, @Param("reason") String reason);

    /**
     * 按状态（可再按原因）分页查询工单（联 {@code post} 取累计风险分，风险分降序 +
     * 举报时间升序）。
     *
     * @param status 工单状态
     * @param reason 举报原因筛选（可空）
     * @param offset 偏移量
     * @param limit  每页条数
     * @return {@link List} 当前页工单行
     */
    List<ReportTicketRow> selectPageByStatus(@Param("status") String status,
            @Param("reason") String reason,
            @Param("offset") int offset, @Param("limit") int limit);

    /**
     * 按 ID 查单条工单详情（联 {@code post} 取标题与累计风险分）。
     *
     * <p>与列表查询分开：详情要回 {@code description}/{@code evidence}（复核材料）
     * 与处理结果三列，而列表刻意不带这些字段——列表是队列视图，多回一次性内容
     * 只会让分页响应变重。</p>
     *
     * @param id 举报 ID
     * @return {@link ReportDetailRow} 详情行；不存在返回 {@code null}
     */
    ReportDetailRow selectDetailById(@Param("id") long id);
}
