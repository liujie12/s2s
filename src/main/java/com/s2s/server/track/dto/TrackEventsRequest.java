package com.s2s.server.track.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies.SnakeCaseStrategy;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 埋点上报请求体（{@code POST /track/events}，Batch1；详设 §5.8）。
 *
 * <p><b>为什么用 SNAKE_CASE 映射</b>：契约字段为 {@code dropped_count} 等下划线命名，
 * 而 Java 惯用驼峰；{@code @JsonNaming(SnakeCaseStrategy.class)} 在 DTO 边界完成一次
 * 转换，业务代码仍用驼峰，避免手写 {@code @JsonProperty} 逐字段漂移。</p>
 *
 * <p><b>为什么 {@code events} 只校验下界（{@code @Size(min=1)}）不校验上界</b>：
 * 契约的上界（{@code maxItems}）对应错误码是 {@code 42906}（埋点限频，needRetryAfter），
 * 而 Bean Validation 越界会被统一映射为 {@code 40001}（参数错误），语义不符。
 * 故上界放在 service 的七步链路第 [3] 步以 {@code 42906} 判决；此处只把「空批次」
 * 这类真正的参数错误挡在入口（{@code 40001}）。</p>
 *
 * @param events       本批事件（至少 1 条；上界由 service 判决为 42906）
 * @param droppedCount 客户端因本地队列溢出而丢弃的事件数（默认 0；&gt;0 时服务端仅记 WARN 日志）
 */
@JsonNaming(SnakeCaseStrategy.class)
public record TrackEventsRequest(
        @NotNull(message = "events 不能为 null")
        @Size(min = 1, message = "events 至少 1 条")
        List<@Valid TrackEventItem> events,
        Integer droppedCount) {
}
