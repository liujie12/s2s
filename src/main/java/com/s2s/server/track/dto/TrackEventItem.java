package com.s2s.server.track.dto;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;
import com.fasterxml.jackson.databind.PropertyNamingStrategies.SnakeCaseStrategy;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;
import java.time.Instant;
import java.util.Map;

/**
 * 单条埋点事件（{@code events} 数组元素；详设 §5.8）。
 *
 * <p>字段与埋点库月表列一一对应（DDL {@code V1__init_track_schema.sql}）：
 * {@code event_name/interaction_id/ts/props/leaf_category_id/completeness_level/
 * is_ai_assisted/grid_id}。{@code request_id} 是契约保留字段（客户端访问日志 join 辅助），
 * 当前月表无同名列，故仅透传不落库（列集合见 DDL，禁自造列）。</p>
 *
 * <p><b>为什么 {@code ts} 定 {@link Instant}</b>：契约要求 ISO-8601 带毫秒；用带时区语义的
 * {@code Instant} 承接客户端上报时刻，落库前统一换算为 {@code DATETIME(3)}（UTC 口径，
 * 与 post 域「入库 LocalDateTime、出参 Instant(UTC)」的既有约定一致）。时区口径是否需
 * 另行约定见交付说明「待确认项」。</p>
 *
 * @param event            事件名（5 值枚举；非法值在反序列化期即失败 → 40001）
 * @param ts               客户端采集时刻（ISO-8601 带毫秒）
 * @param interactionId    交互标识（UUID；与客户端埋点/访问日志的 join 键）
 * @param requestId        可选，请求标识（月表暂无对应列，仅透传）
 * @param props            可选，事件专属属性对象（如 layer_switch 的四段耗时）
 * @param leafCategoryId   可选，维度快照：叶子类目 ID
 * @param completenessLevel 可选，维度快照：完整度档位（0/1/2）
 * @param isAiAssisted     可选，维度快照：是否 AI 辅助发布
 * @param gridId           可选，维度快照：发布点网格 ID
 */
@JsonNaming(SnakeCaseStrategy.class)
public record TrackEventItem(
        @NotNull(message = "event 不能为空")
        EventName event,
        @NotNull(message = "ts 不能为空")
        Instant ts,
        @NotNull(message = "interaction_id 不能为空")
        String interactionId,
        String requestId,
        Map<String, Object> props,
        Integer leafCategoryId,
        Integer completenessLevel,
        Boolean isAiAssisted,
        String gridId) {

    /**
     * 埋点事件名（契约 5 值枚举）。
     *
     * <p><b>为什么自带 wire 值而非依赖 Jackson 默认枚举映射</b>：默认按枚举常量名
     * （{@code LAYER_SWITCH}）匹配，而契约线值为下划线小写（{@code layer_switch}）。
     * 用 {@link JsonValue}/{@link JsonCreator} 把线值绑定在枚举自身，成为唯一口径源，
     * 并让非法值在反序列化期抛错（由全局处理器统一映射为 {@code 40001}）。</p>
     */
    public enum EventName {
        /** 层级切换（props 含四段耗时，详设 §5.8 第 [6] 步一致性校验对象）。 */
        LAYER_SWITCH("layer_switch"),
        /** 帖子发布。 */
        POST_PUBLISHED("post_published"),
        /** 联系事件。 */
        CONTACT_EVENT("contact_event"),
        /** 需求推送送达。 */
        DEMAND_PUSH_SENT("demand_push_sent"),
        /** 资源详情点击。 */
        RESOURCE_DETAIL_CLICK("resource_detail_click");

        private final String wire;

        /**
         * 构造事件名枚举。
         *
         * @param wire 契约线值（下划线小写）
         */
        EventName(String wire) {
            this.wire = wire;
        }

        /**
         * 取契约线值（序列化出口）。
         *
         * @return {@link String} 线值，如 {@code layer_switch}
         */
        @JsonValue
        public String wire() {
            return wire;
        }

        /**
         * 由契约线值反解枚举（反序列化入口）。
         *
         * @param wire 契约线值
         * @return {@link EventName} 匹配的枚举常量
         * @throws IllegalArgumentException 线值不在 5 值白名单内（反序列化失败 → 40001）
         */
        @JsonCreator
        public static EventName fromWire(String wire) {
            for (EventName candidate : values()) {
                if (candidate.wire.equals(wire)) {
                    return candidate;
                }
            }
            throw new IllegalArgumentException("未知埋点事件名: " + wire);
        }
    }
}
