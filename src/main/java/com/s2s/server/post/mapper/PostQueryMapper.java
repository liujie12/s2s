package com.s2s.server.post.mapper;

import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * post 域查询 Mapper（[127]；详设 §5.3.3 读路径）。
 *
 * <p>为什么要独立于 {@code PostMapper}：本 Mapper 承载<b>多表 JOIN / 批量聚合</b>型读查询
 * （详情需 JOIN {@code user} 取作者摘要、我的发布需批量取封面媒体与联系数），
 * 与 {@code PostMapper} 的通用 CRUD 职责不同；沿用 [126] {@code MapPostMapper} 的
 * 「通用 CRUD 走 BaseMapper、性能/联表查询走 XML」范式。</p>
 *
 * <p>返回 {@code Map} 而非实体：详情与列表所需的列集合是「post 列 + user 列」的并集，
 * 无对应实体；列名与 {@code Map} key 逐字对齐（取值方为 service，映射集中在
 * {@code PostQueryService}）。</p>
 */
@Mapper
public interface PostQueryMapper {

    /**
     * 查帖子详情行（含作者摘要列）。
     *
     * @param postId 帖子 ID
     * @return {@link Map} 单行；帖子不存在时返回 {@code null}
     */
    Map<String, Object> selectDetailRow(@Param("postId") Long postId);

    /**
     * 查「我的发布」当前页（不含媒体，媒体由 service 批量补齐）。
     *
     * @param userId          发布者 ID（本人视角）
     * @param dbStatuses      库内状态集合（{@code PostStatus.ApiStatusFilter}）
     * @param reasons         归因集合；空集合表示不限
     * @param allowNullReason 是否放行 {@code status_reason IS NULL}
     * @param offset          偏移量（从 0 起）
     * @param limit           每页条数
     * @return {@link List} 行集合（按发布时间倒序）
     */
    List<Map<String, Object>> selectMine(@Param("userId") Long userId,
            @Param("dbStatuses") List<String> dbStatuses,
            @Param("reasons") List<Integer> reasons,
            @Param("allowNullReason") boolean allowNullReason,
            @Param("offset") int offset,
            @Param("limit") int limit);

    /**
     * 统计「我的发布」符合条件的总数（筛选条件与 {@link #selectMine} 逐条一致）。
     *
     * @param userId          发布者 ID
     * @param dbStatuses      库内状态集合
     * @param reasons         归因集合
     * @param allowNullReason 是否放行 {@code status_reason IS NULL}
     * @return long 总条数
     */
    long countMine(@Param("userId") Long userId,
            @Param("dbStatuses") List<String> dbStatuses,
            @Param("reasons") List<Integer> reasons,
            @Param("allowNullReason") boolean allowNullReason);

    /**
     * 批量统计一批帖子的联系方式被查看次数（{@code contact_event} 按 post_id 聚合）。
     *
     * @param postIds 帖子 ID 列表（非空，调用方保证）
     * @return {@link List} 每行含 {@code post_id} 与 {@code cnt}；无事件的帖子不出现在结果里
     */
    List<Map<String, Object>> countContactEvents(@Param("postIds") List<Long> postIds);
}
