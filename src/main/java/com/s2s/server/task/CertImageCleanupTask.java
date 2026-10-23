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
 * 证照原件图清理任务（保留策略 {@code ocr_image_7d}；2026-10-23 补实现）。
 *
 * <p><b>为什么必须有这个任务</b>：{@code cert.ocr_image_ref} 存的是用户上传的身份证/
 * 营业执照原件，属敏感个人信息；《个人信息保护法》要求「保存期限为实现处理目的所必要的
 * 最短时间」，{@code cert} 表 DDL 与《隐私政策》均对外承诺「核验完成后 7 天内删除」。
 * 此前该策略只登记未实现（{@code RetentionRuleRegistry} 标注 PENDING），构成虚假告知。</p>
 *
 * <p><b>删除次序不可颠倒</b>：先删 OSS 对象、成功后才清 {@code cert.ocr_image_ref}。
 * 反过来的话 OSS 删除失败时引用已丢失，对象再无线索可追溯（引用是找回对象的唯一凭据）。
 * 失败行本批跳过、保留引用，等下次调度重试。</p>
 *
 * <p>只清引用、不删 {@code cert} 行：认证结果（状态/审核时间）需保留可追溯，
 * 与「删除个人信息」义务并不冲突——被删的是原件图，不是认证结论。</p>
 */
@Component
public class CertImageCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(CertImageCleanupTask.class);

    /**
     * 调度表达式：每日 03:20（六段 cron；非整点，避开整点任务高峰与本任务的 OSS 往返）。
     */
    private static final String CRON_DAILY = "0 20 3 * * *";

    /** 记录主键列名（与 {@code TaskMapper.selectExpiredCertImages} 出参逐字一致）。 */
    private static final String COLUMN_ID = "id";

    /** 证照图 OSS 引用列名（同上）。 */
    private static final String COLUMN_OCR_IMAGE_REF = "ocr_image_ref";

    private final TaskMapper taskMapper;
    private final OssClient ossClient;

    /**
     * 构造证照图清理任务。
     *
     * @param taskMapper 定时任务持久层（本任务用 {@code selectExpiredCertImages} /
     *                   {@code clearCertImageRefs}）
     * @param ossClient  对象存储客户端（删除证照原件；dev 桩模式下为本地空实现）
     */
    public CertImageCleanupTask(TaskMapper taskMapper, OssClient ossClient) {
        this.taskMapper = taskMapper;
        this.ossClient = ossClient;
    }

    /**
     * 清理超过保留期的证照原件图（分批推进，OSS 成功后才清引用）。
     *
     * @return void；无到期记录时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void cleanupExpiredCertImages() {
        LocalDateTime threshold =
                LocalDateTime.now().minusDays(NfrRetention.CERT_IMAGE_RETENTION_DAYS);
        int clearedRows = 0;
        int ossFailures = 0;

        for (int batch = 0; batch < NfrTask.CLEANUP_MAX_BATCHES; batch++) {
            List<Map<String, Object>> rows = taskMapper.selectExpiredCertImages(
                    threshold, NfrTask.MEDIA_ORPHAN_BATCH_SIZE);
            if (rows.isEmpty()) {
                break;
            }
            List<Long> clearableIds = new ArrayList<>(rows.size());
            for (Map<String, Object> row : rows) {
                if (removeObjectQuietly(row)) {
                    clearableIds.add(((Number) row.get(COLUMN_ID)).longValue());
                } else {
                    ossFailures++;
                }
            }
            if (clearableIds.isEmpty()) {
                // 本批全部 OSS 删除失败：立刻退出，否则下一轮会重复取到同一批（死循环）
                log.warn("证照图清理本批 {} 行 OSS 删除全部失败，本次调度中止（引用保留待重试）",
                        rows.size());
                break;
            }
            clearedRows += taskMapper.clearCertImageRefs(clearableIds);
            if (rows.size() < NfrTask.MEDIA_ORPHAN_BATCH_SIZE) {
                break;
            }
        }

        if (clearedRows > 0 || ossFailures > 0) {
            log.info("证照图清理：清空引用 {} 行，OSS 删除失败 {} 行（失败行保留引用，下次重试）",
                    clearedRows, ossFailures);
        }
    }

    /**
     * 删除单个证照对象，失败不抛出（单行失败不应拖停整批）。
     *
     * @param row 记录行（含 {@code id} 与 {@code ocr_image_ref}）
     * @return boolean {@code true} 表示对象已删除或确认无需删除，可清引用
     */
    private boolean removeObjectQuietly(Map<String, Object> row) {
        String objectKey = (String) row.get(COLUMN_OCR_IMAGE_REF);
        try {
            ossClient.deleteObject(objectKey);
            return true;
        } catch (RuntimeException exception) {
            log.warn("证照图 OSS 对象删除失败，保留引用待下次重试：certId={}, objectKey={}",
                    row.get(COLUMN_ID), objectKey, exception);
            return false;
        }
    }
}
