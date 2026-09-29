package com.s2s.server.track.dto;

/**
 * 埋点上报响应体（{@code POST /track/events} 200；详设 §5.8）。
 *
 * <p><b>{@code accepted} 的语义是「实际入库事件数」而非「接收条数」</b>：月表以
 * {@code uk_event_dedup(interaction_id, event_name, user_id, ts)} 去重，重复行写入返回
 * 受影响行数 0、新行返回 1，故 {@code accepted} 恰为该批 {@code INSERT ... ON DUPLICATE
 * KEY UPDATE id = id} 的受影响行数之和。客户端据此判断本批是否被消化，避免把
 * 「响应丢在回程」造成的重传误判为丢失。</p>
 *
 * @param accepted 实际入库（去重后净新增）的事件数
 */
public record TrackEventsResponse(int accepted) {
}
