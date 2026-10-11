package com.s2s.server.contact.mapper;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 收藏域 Mapper（[B2-11]；DDL {@code favorite} 表；openapi {@code POST/DELETE
 * /posts/{id}/favorite}、{@code GET /favorites}）。
 *
 * <p><b>域归属 = contact</b>：架构文档 §3（R9）域切分把「收藏」列入 contact 职责，表→域映射
 * 亦把 {@code favorite} 归 contact；openapi 原 {@code x-domain: post} 为笔误，已于 2026-10-11
 * 裁定更正为 contact。</p>
 *
 * <p><b>跨域数据访问边界</b>：本 Mapper 的 SQL 会读取/联表 {@code post}（列表需帖子列、收藏前
 * 需判帖子存在）——这是<b>数据层</b>的只读联表，未注入他域 Mapper Bean，符合架构文档 §3「不
 * 允许跨域直接访问对方的 mapper」的原意；封面等需视角判定的数据走 post 域 service。</p>
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
