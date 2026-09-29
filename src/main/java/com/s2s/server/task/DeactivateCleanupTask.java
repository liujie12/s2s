package com.s2s.server.task;

import com.s2s.server.common.constants.NfrRetention;
import com.s2s.server.post.OssClient;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 注销冷静期到期清理任务（[129] P4；架构 §8 任务 7；详设 §6 任务 #7；PRD §3.7 / §9.7）。
 *
 * <p><b>这是合规义务，不是清理优化</b>（架构 §8 三条口径说明第 2 条）：冷静期内可撤回、
 * 撤回后数据原封不动；满 {@link NfrRetention#DEACTIVATE_COOLING_DAYS} 天未撤回则<b>必须</b>
 * 删除个人数据，否则加密手机号与实名结果会永久留存。</p>
 *
 * <p><b>清理粒度必须是 {@code user_id}</b>：撤回注销会清空 {@code user.deactivate_at}
 * （故「非空且超期」即待清理），而身份行按 {@code user_id} 全删——Batch2 起同一账号会挂
 * {@code wechat} 等多行身份，只删 {@code phone} 那一行会让残留身份可登录、注销承诺失效
 * （架构 §8 口径说明第 2 条）。</p>
 *
 * <p><b>四步清理（第 4 步为 2026-09-29 用户裁定）</b>：</p>
 * <ol>
 *   <li>按 {@code user_id} 删除 {@code user_identity} 全部行（含手机号原文密文）；</li>
 *   <li>清空 {@code user} 的实名结果（{@code real_name_enc} / {@code id_card_hash} /
 *       {@code id_card_last4}）；</li>
 *   <li>清空 {@code user.phone_mask}；</li>
 *   <li><b>连帖子一并删除</b>：架构 §8 与数据库设计 §5 都要求删除「联系方式」，而
 *       {@code post.contact_value_enc} 是 {@code NOT NULL} 列、无法置空；可行且彻底的路径
 *       就是删除该用户名下的帖子（连同其 {@code post_media} 登记与 OSS 对象）。
 *       <b>该步与保留策略 {@code post_archived_keep}（下架帖不物理删除，供收藏与申诉追溯）
 *       的优先级冲突已经用户裁定：注销属个人信息删除义务（PIPL），优先级更高</b>——
 *       帖子只要还在，联系方式就仍可被 {@code /contact} 解密，注销承诺即未履行。
 *       裁定与登记见说明文档 §2.9。</li>
 * </ol>
 *
 * <p><b>删除次序</b>：先取帖子 ID → 取媒体登记（登记行是找回 OSS 对象的唯一凭据，
 * 先删登记即失去线索）→ 逐对象删 OSS（单行失败不中断，记 WARN）→ 删媒体登记 → 删帖子 →
 * 删身份行 → 清用户实名与掩码。任何一步的失败都不影响后续步骤，避免「媒体清理失败导致
 * 合规删除整体不执行」。</p>
 *
 * <p>调度频率取详设 §6 任务列「每日」。</p>
 */
@Component
public class DeactivateCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(DeactivateCleanupTask.class);

    /**
     * 调度表达式：每日 05:00（六段 cron；详设 §6 只规定「每日」，具体时刻取业务低峰）。
     */
    private static final String CRON_DAILY = "0 0 5 * * *";

    /** 媒体登记行主键列名（与 {@code TaskMapper.selectMediaByPostIds} 出参一致）。 */
    private static final String COLUMN_ID = "id";

    /** OSS 对象键列名（同上）。 */
    private static final String COLUMN_OBJECT_KEY = "object_key";

    private final TaskMapper taskMapper;
    private final OssClient ossClient;

    /**
     * 构造注销清理任务。
     *
     * @param taskMapper 定时任务持久层
     * @param ossClient  对象存储客户端（删除注销用户帖子下的媒体对象）
     */
    public DeactivateCleanupTask(TaskMapper taskMapper, OssClient ossClient) {
        this.taskMapper = taskMapper;
        this.ossClient = ossClient;
    }

    /**
     * 清理冷静期已满的注销用户个人数据（四步，见类注释）。
     *
     * @return void；无待清理用户时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void purgeDeactivatedUsers() {
        LocalDateTime threshold =
                LocalDateTime.now().minusDays(NfrRetention.DEACTIVATE_COOLING_DAYS);
        List<Long> userIds = taskMapper.selectDeactivatingUserIds(threshold);
        if (userIds.isEmpty()) {
            return;
        }

        // 第 4 步的前置：先取帖子与媒体登记，再删对象与登记（登记行是找回对象的唯一凭据）
        List<Long> postIds = taskMapper.selectPostIdsByUserIds(userIds);
        int mediaRows = 0;
        int ossFailureRows = 0;
        if (!postIds.isEmpty()) {
            List<Map<String, Object>> medias = taskMapper.selectMediaByPostIds(postIds);
            for (Map<String, Object> media : medias) {
                try {
                    ossClient.deleteObject((String) media.get(COLUMN_OBJECT_KEY));
                } catch (RuntimeException exception) {
                    ossFailureRows++;
                    log.warn("注销清理：媒体对象删除失败，将连同登记行一并移除"
                                    + "（对象可能滞留 OSS，需人工核对）：mediaId={}, objectKey={}",
                            media.get(COLUMN_ID), media.get(COLUMN_OBJECT_KEY), exception);
                }
            }
            mediaRows = taskMapper.deleteMediaByPostIds(postIds);
        }
        int postRows = taskMapper.deletePostsByUserIds(userIds);

        int identityRows = taskMapper.deleteIdentitiesByUserIds(userIds);
        int userRows = taskMapper.clearUserPersonalData(userIds);

        log.info("注销冷静期清理：用户 {} 个，身份行 {} 行，实名与掩码清空 {} 行，"
                        + "帖子 {} 行，媒体登记 {} 行（OSS 删除失败 {} 行）",
                userIds.size(), identityRows, userRows, postRows, mediaRows, ossFailureRows);
        if (ossFailureRows > 0) {
            log.warn("注销清理存在 OSS 对象删除失败 {} 行——登记行已随帖子删除，"
                    + "这些对象不再有任何线索可追溯，须人工在桶内核对清理", ossFailureRows);
        }
    }
}
