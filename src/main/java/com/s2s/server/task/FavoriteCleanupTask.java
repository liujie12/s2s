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
 * 取消收藏记录清理任务（[129] P4；架构 §8 任务 6；详设 §6 任务 #6）。
 *
 * <p>物理删除软删满 {@link NfrRetention#FAVORITE_DELETED_RETENTION_DAYS} 天的 {@code favorite} 行。
 * 软删期内（30 天）保留是为了「取消收藏误操作可恢复」（PRD §8.7），到期才真正物删——
 * 这是 PRD §13.4 的 `favorite_deleted_30d` 承诺。</p>
 *
 * <p>批次参数见 {@link NfrTask}；调度频率取详设 §6 任务列「每日」。</p>
 */
@Component
public class FavoriteCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(FavoriteCleanupTask.class);

    /**
     * 调度表达式：每日 04:40（六段 cron；详设 §6 只规定「每日」，具体时刻取业务低峰）。
     */
    private static final String CRON_DAILY = "0 40 4 * * *";

    private final TaskMapper taskMapper;

    /**
     * 构造收藏记录清理任务。
     *
     * @param taskMapper 定时任务持久层（本任务只用 {@code deleteFavoritesBefore}）
     */
    public FavoriteCleanupTask(TaskMapper taskMapper) {
        this.taskMapper = taskMapper;
    }

    /**
     * 物理删除软删超期的收藏行（分批推进直到收敛）。
     *
     * @return void；无超期行时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void deleteExpiredFavorites() {
        LocalDateTime threshold =
                LocalDateTime.now().minusDays(NfrRetention.FAVORITE_DELETED_RETENTION_DAYS);
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(
                limit -> taskMapper.deleteFavoritesBefore(threshold, limit));

        if (result.affectedRows() > 0) {
            log.info("取消收藏记录清理：物删 {} 行（软删保留 {} 天）",
                    result.affectedRows(), NfrRetention.FAVORITE_DELETED_RETENTION_DAYS);
        }
        if (!result.converged()) {
            log.warn("取消收藏记录清理未在 {} 批内收敛，本批删除 {} 行——下次调度继续",
                    NfrTask.CLEANUP_MAX_BATCHES, result.affectedRows());
        }
    }
}
