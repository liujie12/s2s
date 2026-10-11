package com.s2s.server.notify.mapper;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 通知域读 Mapper（[129]；DDL {@code V1__init_schema.sql} 的 {@code notification} 表）。
 *
 * <p>Batch1 只读；[B2-11] 起追加「标记已读」两条写语句（{@code POST /notifications/read}，
 * 推送偏好仍为 Batch2 占位）。查询各自出必要的列，绝不 {@code SELECT *}。</p>
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

    /**
     * 标记该用户「全部未读」为已读（PRD §8.3.3「全部已读」按钮）。
     *
     * @param userId 接收者 user_id
     * @param readAt 已读时刻（由 service 传入，口径统一可测）
     * @return int 实际置位行数（幂等：无未读行时为 0）
     */
    int markAllRead(@Param("userId") Long userId, @Param("readAt") LocalDateTime readAt);

    /**
     * 按 id 批量标记已读（限定归属当前用户，防越权标记他人通知）。
     *
     * @param userId 接收者 user_id
     * @param ids    通知 ID 列表（非空，调用方保证）
     * @param readAt 已读时刻
     * @return int 实际置位行数
     */
    int markReadByIds(@Param("userId") Long userId, @Param("ids") List<Long> ids,
            @Param("readAt") LocalDateTime readAt);
}
