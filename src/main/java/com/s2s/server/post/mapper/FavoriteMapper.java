package com.s2s.server.post.mapper;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 收藏域 Mapper（[B2-11]；DDL {@code favorite} 表；openapi {@code POST/DELETE
 * /posts/{id}/favorite}、{@code GET /favorites}）。
 *
 * <p><b>为什么独立于 {@code PostMapper}/{@code PostQueryMapper}</b>：收藏是「用户 × 帖子」
 * 的关系读写（唯一键 {@code uk_user_post} + 软删复活），与 post 的 CRUD/联表读语义不同；
 * 沿用「按用途分 Mapper」的既有范式（{@code PostQueryMapper} 亦为独立读 Mapper）。</p>
 *
 * <p><b>列集合纪律</b>：列表查询只出卡片所需列，禁 {@code SELECT *}。</p>
 */
@Mapper
public interface FavoriteMapper {

    /**
     * 判断帖子是否存在（收藏前置校验：不存在回 {@code 41001}）。
     *
     * @param postId 帖子 ID
     * @return int 命中行数（0＝不存在）
     */
    int countPostById(@Param("postId") Long postId);

    /**
     * 收藏（幂等写）：不存在则插入，存在则把 {@code deleted_at} 复活为 {@code NULL}。
     *
     * <p>用 {@code INSERT ... ON DUPLICATE KEY UPDATE} 一条语句完成「插入或复活」，
     * 由物理唯一键 {@code uk_user_post} 保证并发幂等（PRD §13 favorite 表口径）。</p>
     *
     * @param userId 收藏者 ID
     * @param postId 帖子 ID
     * @return int 受影响行数（新建 1 / 复活 2 / 已是收藏态 0）
     */
    int upsertFavorite(@Param("userId") Long userId, @Param("postId") Long postId);

    /**
     * 取消收藏（软删，幂等）。
     *
     * <p>只对当前未删行置 {@code deleted_at}（{@code deleted_at IS NULL} 条件保证重复取消
     * 不刷新时间戳）；软删记录由 {@code FavoriteCleanupTask} 30 天后物删。</p>
     *
     * @param userId    收藏者 ID
     * @param postId    帖子 ID
     * @param deletedAt 软删时刻（由 service 传入，便于测试与口径统一）
     * @return int 实际更新行数（未收藏时为 0）
     */
    int softDeleteFavorite(@Param("userId") Long userId,
            @Param("postId") Long postId,
            @Param("deletedAt") LocalDateTime deletedAt);

    /**
     * 统计某用户未删收藏总数（按 {@code type} 可选筛选）。
     *
     * @param userId 收藏者 ID
     * @param type   帖子供需态线值（{@code resource}/{@code demand}）；{@code null} 表示全部
     * @return long 符合条件条数
     */
    long countByUser(@Param("userId") Long userId, @Param("type") String type);

    /**
     * 分页取某用户未删收藏列表（JOIN {@code post} 取卡片列，按收藏时间倒序）。
     *
     * @param userId 收藏者 ID
     * @param type   帖子供需态线值；{@code null} 表示全部
     * @param offset 偏移量（从 0 起）
     * @param limit  本次取数上限
     * @return {@link List} 每行含 {@code post_id} / {@code type} / {@code leaf_category_id} /
     *         {@code l2_category_id} / {@code title} / {@code price} / {@code price_unit} /
     *         {@code completeness_level} / {@code status} / {@code status_reason} /
     *         {@code created_at}（发布时间）/ {@code favorite_at}
     */
    List<Map<String, Object>> selectPage(@Param("userId") Long userId, @Param("type") String type,
            @Param("offset") int offset, @Param("limit") int limit);
}
