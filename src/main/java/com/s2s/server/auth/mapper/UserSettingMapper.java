package com.s2s.server.auth.mapper;

import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 用户设置 Mapper（[B2-11]；DDL {@code user_setting} 表，V6 迁移；openapi
 * {@code GET/PATCH /settings}）。
 *
 * <p>1:1 与 {@code user}（{@code user_id} 即主键）。查询只出通知开关四列，绝不 {@code SELECT *}。</p>
 */
@Mapper
public interface UserSettingMapper {

    /**
     * 查某用户的设置行。
     *
     * @param userId 用户 ID
     * @return {@link Map} 含 {@code notify_enabled}/{@code notify_system}/{@code notify_interaction}/
     *         {@code notify_cert}/{@code personalized_recommend}；无该行时返回 {@code null}（由 service 兜底为默认）
     */
    Map<String, Object> selectByUserId(@Param("userId") Long userId);

    /**
     * 写入设置（幂等 upsert）：无行则插入，有行则整行覆盖。
     *
     * <p>由主键 {@code user_id} 触发 {@code ON DUPLICATE KEY UPDATE}；值取插入值（MySQL 8.0.19+
     * 的 {@code AS new} 别名，避免已废弃的 {@code VALUES()} 写法）。</p>
     *
     * @param userId                用户 ID
     * @param notifyEnabled         消息通知总开关（true=开）
     * @param notifySystem          系统通知分通道
     * @param notifyInteraction     互动通知分通道
     * @param notifyCert            认证通知分通道
     * @param personalizedRecommend 个性化排序开关（false=关闭，列表仅按距离排序）
     * @param aiImproveEnabled      AI 数据用于改进解析开关（false=仅用于当次解析）
     * @return int 受影响行数
     */
    int upsert(@Param("userId") Long userId,
            @Param("notifyEnabled") boolean notifyEnabled,
            @Param("notifySystem") boolean notifySystem,
            @Param("notifyInteraction") boolean notifyInteraction,
            @Param("notifyCert") boolean notifyCert,
            @Param("personalizedRecommend") boolean personalizedRecommend,
            @Param("aiImproveEnabled") boolean aiImproveEnabled);
}
