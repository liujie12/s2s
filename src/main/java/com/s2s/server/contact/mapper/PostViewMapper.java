package com.s2s.server.contact.mapper;

import java.time.LocalDate;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 浏览计数 Mapper（{@code post_view} 明细 + {@code post_view_daily} 日计数）。
 *
 * <p><b>域归属 = contact</b>：openapi {@code /posts/{post_id}/view} 标 {@code x-domain: contact}。
 * 写路径只在本域；读路径（帖主计数）由 post 域查询 Mapper 批量聚合。</p>
 */
@Mapper
public interface PostViewMapper {

    /**
     * 取帖子作者 ID（用于排除作者自浏览；同时判帖子是否存在）。
     *
     * @param postId 帖子 ID
     * @return {@link Long} 作者 user_id；帖子不存在时返回 {@code null}
     */
    Long selectPostOwner(@Param("postId") Long postId);

    /**
     * 统计某帖子某日某去重键的明细是否存在。
     *
     * @param postId    帖子 ID
     * @param viewerKey 去重键（{@code user:<id>} / {@code device:<uuid>}）
     * @param viewDay   业务日
     * @return int 命中行数
     */
    int countView(@Param("postId") Long postId,
            @Param("viewerKey") String viewerKey,
            @Param("viewDay") LocalDate viewDay);

    /**
     * 插入一条浏览明细（唯一键冲突由 service 捕获按「已去过重」处理）。
     *
     * @param postId    帖子 ID
     * @param viewerKey 去重键
     * @param viewDay   业务日
     * @return int 影响行数（正常插入为 1）
     */
    int insertView(@Param("postId") Long postId,
            @Param("viewerKey") String viewerKey,
            @Param("viewDay") LocalDate viewDay);

    /**
     * 删除某帖子某日某去重键的明细（登录时合并当日游客行）。
     *
     * @param postId    帖子 ID
     * @param viewerKey 去重键
     * @param viewDay   业务日
     * @return int 实际删除行数
     */
    int deleteView(@Param("postId") Long postId,
            @Param("viewerKey") String viewerKey,
            @Param("viewDay") LocalDate viewDay);

    /**
     * 日计数增减（delta 可为负；行不存在时插入）。
     *
     * @param postId  帖子 ID
     * @param viewDay 业务日
     * @param delta   增量（-1 / 0 / 1）
     * @return int 影响行数
     */
    int upsertDaily(@Param("postId") Long postId,
            @Param("viewDay") LocalDate viewDay,
            @Param("delta") int delta);
}
