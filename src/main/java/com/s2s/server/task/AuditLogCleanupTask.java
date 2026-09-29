package com.s2s.server.task;

import com.s2s.server.common.constants.NfrRetention;
import com.s2s.server.common.constants.NfrTask;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.LocalDateTime;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 审计日志清理任务（[129] P4；架构 §8 任务 4；详设 §6 任务 #4）。
 *
 * <p>删除超过 {@link NfrRetention#AUDIT_LOG_RETENTION_DAYS} 天的 {@code audit_log} 行。</p>
 *
 * <p><b>为什么保留期是 180 天且不可下调</b>：它是 BRD:268 的合规下限（可观测 §2 明写
 * 「审计 180 天是合规决定的，不能调」），与埋点 90 天（运维口径、可按盘容量调）不是一个
 * 来源。实现时最容易被「顺手统一成一个配置」——那会在合规上出问题，故两者各自引用
 * 自己的常量。</p>
 *
 * <p>批次参数见 {@link NfrTask}；调度频率取详设 §6 任务列「每日」（具体时刻设计未定，
 * 取业务低峰）。</p>
 */
@Component
public class AuditLogCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(AuditLogCleanupTask.class);

    /**
     * 调度表达式：每日 04:30（六段 cron；详设 §6 只规定「每日」，具体时刻取业务低峰）。
     */
    private static final String CRON_DAILY = "0 30 4 * * *";

    private final TaskMapper taskMapper;

    /**
     * 构造审计日志清理任务。
     *
     * @param taskMapper 定时任务持久层（本任务只用 {@code deleteAuditLogsBefore}）
     */
    public AuditLogCleanupTask(TaskMapper taskMapper) {
        this.taskMapper = taskMapper;
    }

    /**
     * 删除超过保留期的审计行（分批推进直到收敛）。
     *
     * @return void；无过期行时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void deleteExpiredAuditLogs() {
        LocalDateTime threshold = LocalDateTime.now().minusDays(NfrRetention.AUDIT_LOG_RETENTION_DAYS);
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(
                limit -> taskMapper.deleteAuditLogsBefore(threshold, limit));

        if (result.affectedRows() > 0) {
            log.info("审计日志清理：删除 {} 行（保留 {} 天，threshold={}）",
                    result.affectedRows(), NfrRetention.AUDIT_LOG_RETENTION_DAYS, threshold);
        }
        if (!result.converged()) {
            log.warn("审计日志清理未在 {} 批内收敛，本批删除 {} 行——下次调度继续",
                    NfrTask.CLEANUP_MAX_BATCHES, result.affectedRows());
        }
    }
}
