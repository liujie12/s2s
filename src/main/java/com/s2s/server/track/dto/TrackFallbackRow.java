package com.s2s.server.track.dto;

import java.time.LocalDateTime;

/**
 * 兜底表待搬运行（仅搬运任务需要的两列）。
 *
 * <p>为什么只取 {@code id} 与 {@code ts}：搬运分两步——先按 {@code ts} 归月批量插入月表，
 * 再按 {@code id} 删除已搬运行；其余列由 SQL 在库内直接 {@code INSERT ... SELECT} 复制，
 * 不经过 Java 对象，避免逐列搬运造成漏列或类型漂移。</p>
 */
public class TrackFallbackRow {

    /** 兜底行 ID（删除已搬运行的唯一定位键）。 */
    private Long id;

    /** 客户端采集时刻（UTC，搬运任务据此判定目标月表）。 */
    private LocalDateTime ts;

    /**
     * 取兜底行 ID。
     *
     * @return {@link Long} 行 ID
     */
    public Long getId() {
        return id;
    }

    /**
     * 设置兜底行 ID（MyBatis 反射赋值用）。
     *
     * @param id 行 ID
     * @return void
     */
    public void setId(Long id) {
        this.id = id;
    }

    /**
     * 取客户端采集时刻。
     *
     * @return {@link LocalDateTime} UTC 采集时刻
     */
    public LocalDateTime getTs() {
        return ts;
    }

    /**
     * 设置客户端采集时刻（MyBatis 反射赋值用）。
     *
     * @param ts UTC 采集时刻
     * @return void
     */
    public void setTs(LocalDateTime ts) {
        this.ts = ts;
    }
}
