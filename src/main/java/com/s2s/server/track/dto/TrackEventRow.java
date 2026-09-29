package com.s2s.server.track.dto;

import java.time.LocalDateTime;

/**
 * 埋点事件落库行（批量 {@code INSERT} 的 {@code <foreach>} 元素）。
 *
 * <p><b>为什么需要它、而不是直接 foreach {@link TrackEventItem}</b>：{@code props} 在请求里
 * 是对象（{@code Map}），而月表列是 {@code JSON}，落库前必须先在 Java 侧序列化为
 * JSON 文本——这一步只能在 service 完成。本 record 承载「已就绪的列值」，使 XML 只做
 * 占位符拼装、不夹带任何序列化逻辑。</p>
 *
 * <p><b>它不是 MyBatis-Plus 实体</b>：埋点库无 entity（详设 §1.2 定案），本 record
 * 不继承 {@code BaseMapper}、不参与 ORM 映射，仅是 {@code @Param} 集合的元素载体。</p>
 *
 * @param eventName         事件名线值（写入 {@code event_name}）
 * @param interactionId     交互标识（写入 {@code interaction_id}）
 * @param ts                采集时刻，已换算为 UTC 的 {@code DATETIME(3)}（写入 {@code ts}）
 * @param propsJson         props 的 JSON 文本（写入 {@code props}）；无 props 时为 null
 * @param leafCategoryId    叶子类目 ID（写入 {@code leaf_category_id}）
 * @param completenessLevel 完整度档位（写入 {@code completeness_level}）
 * @param isAiAssisted      是否 AI 辅助（写入 {@code is_ai_assisted}）
 * @param gridId            发布点网格 ID（写入 {@code grid_id}）
 */
public record TrackEventRow(
        String eventName,
        String interactionId,
        LocalDateTime ts,
        String propsJson,
        Integer leafCategoryId,
        Integer completenessLevel,
        Boolean isAiAssisted,
        String gridId) {
}
