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
 * 联系事件（中转日志）清理任务（保留策略 {@code transit_log_30d}；2026-10-23 补实现）。
 *
 * <p><b>载体裁定</b>：设计文档只说「联系中转脱敏日志保留 30 天」，未指定落库对象。
 * 实际唯一承载联系动作的表是 {@code contact_event}（字段：post_id / from_user_id /
 * to_user_id / channel_type / created_at），它同时服务于三维日限判定与北极星辅助指标。
 * 故以该表为「中转日志」的载体，按 {@link NfrRetention#TRANSIT_LOG_RETENTION_DAYS} 天清理；
 * 表内不含联系方式明文（明文只在解密返回时瞬时存在），清理即完成告知义务。</p>
 *
 * <p>删过期行对限频无影响：限频只查「当日」窗口，而清理阈值是 30 天前。</p>
 */
@Component
public class ContactEventCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(ContactEventCleanupTask.class);

    /**
     * 调度表达式：每日 03:40（六段 cron；与证照图清理错峰，避免同时争抢 DB 连接）。
     */
    private static final String CRON_DAILY = "0 40 3 * * *";

    private final TaskMapper taskMapper;

    /**
     * 构造联系事件清理任务。
     *
     * @param taskMapper 定时任务持久层（本任务用 {@code deleteContactEventsBefore}）
     */
    public ContactEventCleanupTask(TaskMapper taskMapper) {
        this.taskMapper = taskMapper;
    }

    /**
     * 删除超过保留期的联系事件（分批推进，直至无到期行或达到批次上限）。
     *
     * @return void；无到期记录时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void cleanupExpiredContactEvents() {
        LocalDateTime threshold =
                LocalDateTime.now().minusDays(NfrRetention.TRANSIT_LOG_RETENTION_DAYS);
        int deletedRows = 0;

        for (int batch = 0; batch < NfrTask.CLEANUP_MAX_BATCHES; batch++) {
            int affected = taskMapper.deleteContactEventsBefore(
                    threshold, NfrTask.CLEANUP_BATCH_SIZE);
            deletedRows += affected;
            if (affected < NfrTask.CLEANUP_BATCH_SIZE) {
                break;
            }
        }

        if (deletedRows > 0) {
            log.info("联系事件清理：删除 {} 行（保留 {} 天）",
                    deletedRows, NfrRetention.TRANSIT_LOG_RETENTION_DAYS);
        }
    }
}
