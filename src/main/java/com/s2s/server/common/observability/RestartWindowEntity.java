package com.s2s.server.common.observability;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 服务端启动时间窗实体（映射表 {@code restart_window}；详设 §21 缺口 #1；可观测性 §4.2.2）。
 *
 * <p>字段与 DDL {@code V2__restart_window.sql} 逐列对齐：{@code start_at} = 应用开始启动
 * 时刻、{@code end_at} = 启动完成时刻 + {@link com.s2s.server.common.constants.NfrObs#RESTART_WARMUP_MINUTES}
 * 分钟。本表只增不删，行数 == 启动次数（极少），消费方 P95 统计以
 * {@code NOT EXISTS (SELECT 1 FROM restart_window w WHERE e.ts BETWEEN w.start_at AND w.end_at)}
 * 过滤落在预热窗内的事件（可观测性 §4.2.2）。</p>
 */
@TableName("restart_window")
public class RestartWindowEntity {

    /** 行 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 启动时刻（应用开始启动）。 */
    private LocalDateTime startAt;

    /** 预热期结束时刻 = 启动完成时刻 + 重启预热窗口时长（分钟）。 */
    private LocalDateTime endAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public LocalDateTime getStartAt() {
        return startAt;
    }

    public void setStartAt(LocalDateTime startAt) {
        this.startAt = startAt;
    }

    public LocalDateTime getEndAt() {
        return endAt;
    }

    public void setEndAt(LocalDateTime endAt) {
        this.endAt = endAt;
    }
}
