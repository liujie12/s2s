package com.s2s.server.notify.mapper;

import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 通知域读 Mapper（[129]；DDL {@code V1__init_schema.sql} 的 {@code notification} 表）。
 *
 * <p>Batch1 只有查询（详设 §5.6：标记已读与推送偏好为 Batch2），故本 Mapper 只读不写，
 * 三个查询各自出必要的列，绝不 {@code SELECT *}。</p>
 *
 * <p><b>软删口径</b>：所有查询一律带 {@code deleted_at IS NULL}——软删行对用户不存在，
 * 该条件写在 SQL 里而非 Java 过滤（否则分页 {@code total} 会把已删行算进去）。</p>
 */
@Mapper
public interface NotificationMapper {

    /**
     * 统计某用户的通知总数（按类型可选筛选）。
     *
     * @param userId    接收者 user_id
     * @param type      通知类型线值（{@code system}/{@code interaction}/{@code cert}）；
     *                  {@code null} 表示全部
     * @return long 符合条件（未软删）的通知条数
     */
    long countByUser(@Param("userId") Long userId, @Param("type") String type);

    /**
     * 分页取某用户的通知列表（{@code created_at} 倒序，同秒按 {@code id} 倒序稳定）。
     *
     * @param userId 接收者 user_id
     * @param type   通知类型线值；{@code null} 表示全部
     * @param offset 偏移量（从 0 起）
     * @param limit  本次取数上限
     * @return {@link List} 通知行；每行六列 {@code id} / {@code type} / {@code title} /
     *         {@code summary} / {@code target_id} / {@code created_at} / {@code read_at}
     */
    List<Map<String, Object>> selectPage(@Param("userId") Long userId, @Param("type") String type,
            @Param("offset") int offset, @Param("limit") int limit);

    /**
     * 统计某用户的未读通知总数（跨三 Tab，供客户端 Tab 角标）。
     *
     * <p>契约明写「未读总数，用于 Tab 角标」，故<b>不随 {@code type} 筛选收窄</b>——
     * 角标是「所有 Tab 加起来还有多少没看」，按 Tab 收窄会让数字随切 Tab 跳动。</p>
     *
     * @param userId 接收者 user_id
     * @return long 未读（{@code read_at IS NULL} 且未软删）条数
     */
    long countUnread(@Param("userId") Long userId);
}
