package com.s2s.server.task;

import com.s2s.server.common.constants.NfrRetention;
import com.s2s.server.common.constants.NfrTask;
import com.s2s.server.post.OssClient;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 24h 未 commit 的媒体孤儿清理任务（[129] P4；架构 §5.1 第 7 条 + §8 任务 9；
 * 详设 §6 任务 #9）。
 *
 * <p><b>为什么必须有这个任务</b>（架构 §5.1 第 7 条原文）：客户端传完就退出、不调
 * {@code commit}，图片已在桶里却没有任何审核记录，成为既不可见也不会被回收的孤儿对象，
 * 长期累积会撑爆 40G 存储配额。故对创建超过
 * {@link NfrRetention#MEDIA_PENDING_TTL_HOURS} 小时仍为 {@code pending} 且
 * {@code post_id IS NULL} 的登记行，连同 OSS 对象一并清理。</p>
 *
 * <p><b>删除次序不可颠倒</b>：先删 OSS 对象、成功后才删登记行。反过来的话，OSS 删除失败时
 * 登记行已消失，对象就再没有任何线索可追溯（登记行是找回对象的唯一凭据）。OSS 删除失败的
 * 行本批跳过、保留登记，等下次调度重试。</p>
 *
 * <p>调度频率取详设 §6 任务列「每小时」。</p>
 */
@Component
public class MediaOrphanCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(MediaOrphanCleanupTask.class);

    /**
     * 调度表达式：每小时的第 15 分钟（六段 cron；详设 §6 只规定「每小时」，取非整点避免与整点任务撞峰）。
     */
    private static final String CRON_HOURLY = "0 15 * * * *";

    /** 登记行主键列名（与 {@code TaskMapper.selectPendingMedia} 出参逐字一致）。 */
    private static final String COLUMN_ID = "id";

    /** OSS 对象键列名（同上）。 */
    private static final String COLUMN_OBJECT_KEY = "object_key";

    private final TaskMapper taskMapper;
    private final OssClient ossClient;

    /**
     * 构造媒体孤儿清理任务。
     *
     * @param taskMapper 定时任务持久层（本任务用 {@code selectPendingMedia} / {@code deleteMediaByIds}）
     * @param ossClient  对象存储客户端（删除孤儿对象；dev 桩模式下为本地空实现）
     */
    public MediaOrphanCleanupTask(TaskMapper taskMapper, OssClient ossClient) {
        this.taskMapper = taskMapper;
        this.ossClient = ossClient;
    }

    /**
     * 清理超时未 commit 的孤儿媒体（分批推进，OSS 成功后才删登记）。
     *
     * @return void；无孤儿时不产生日志
     */
    @Scheduled(cron = CRON_HOURLY)
    public void cleanupOrphanMedia() {
        LocalDateTime threshold =
                LocalDateTime.now().minusHours(NfrRetention.MEDIA_PENDING_TTL_HOURS);
        int deletedRows = 0;
        int ossFailures = 0;

        for (int batch = 0; batch < NfrTask.CLEANUP_MAX_BATCHES; batch++) {
            List<Map<String, Object>> rows =
                    taskMapper.selectPendingMedia(threshold, NfrTask.MEDIA_ORPHAN_BATCH_SIZE);
            if (rows.isEmpty()) {
                break;
            }
            List<Long> removableIds = new ArrayList<>(rows.size());
            for (Map<String, Object> row : rows) {
                if (removeObjectQuietly(row)) {
                    removableIds.add(((Number) row.get(COLUMN_ID)).longValue());
                } else {
                    ossFailures++;
                }
            }
            if (removableIds.isEmpty()) {
                // 本批全部 OSS 删除失败：立刻退出，否则下一轮会重复取到同一批（死循环）
                log.warn("媒体孤儿清理本批 {} 行 OSS 删除全部失败，本次调度中止（登记行保留待重试）",
                        rows.size());
                break;
            }
            deletedRows += taskMapper.deleteMediaByIds(removableIds);
            if (rows.size() < NfrTask.MEDIA_ORPHAN_BATCH_SIZE) {
                break;
            }
        }

        if (deletedRows > 0 || ossFailures > 0) {
            log.info("媒体孤儿清理：删除登记 {} 行，OSS 删除失败 {} 行（失败行保留登记，下次重试）",
                    deletedRows, ossFailures);
        }
    }

    /**
     * 删除单个 OSS 对象，失败不抛出（本任务对单行失败必须容错，否则一行失败会拖停整批）。
     *
     * @param row 登记行（含 {@code id} 与 {@code object_key}）
     * @return boolean {@code true} 表示对象已删除或确认无需删除，可删登记行
     */
    private boolean removeObjectQuietly(Map<String, Object> row) {
        String objectKey = (String) row.get(COLUMN_OBJECT_KEY);
        try {
            ossClient.deleteObject(objectKey);
            return true;
        } catch (RuntimeException exception) {
            log.warn("媒体孤儿 OSS 对象删除失败，保留登记待下次重试：mediaId={}, objectKey={}",
                    row.get(COLUMN_ID), objectKey, exception);
            return false;
        }
    }
}
