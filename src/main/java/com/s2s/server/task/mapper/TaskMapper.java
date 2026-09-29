package com.s2s.server.task.mapper;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 定时任务持久层 Mapper（[129] P4；架构 §8 任务表；详设 §6）。
 *
 * <p><b>为什么任务共用一支 Mapper 而不是各域自带</b>：这些语句的共同点是「由调度器按时间
 * 条件驱动的批量维护操作」，与任何域的对外语义无关（域内 service 不消费它们）。
 * 若分散到各域 Mapper，会让「批删/批改」这类高危语句混进对外读路径的 Mapper 里，
 * 后人审查时无法一眼看出「哪些语句只由定时任务调用」。故独立成 {@code task.mapper} 包，
 * 一域一词、边界清晰。</p>
 *
 * <p><b>与本类的调用契约</b>：所有方法都接受<b>由任务侧算好的时间阈值</b>（不接收「天数」），
 * 时间基准与换算集中在任务类（便于断言「阈值 = 当前时刻 − N 天」这一唯一口径）；
 * 批量语句一律带 {@code LIMIT}（除按主键 IN 的定向删除），由任务侧循环收敛。</p>
 */
@Mapper
public interface TaskMapper {

    /**
     * 到期帖自动下架（架构 §8 任务 1；详设 §5.3.3 写守卫分流）。
     *
     * <p>守 {@code status='active'}（合法前驱集），<b>不守 version</b>——定时任务不持有用户
     * 视图的 version，若也守则会被用户的并发编辑饿死（详设 §5.3.3 明文的例外）。
     * {@code status_reason=1} 是「到期自动下架」的库内归因（对外派生为 {@code expired}，
     * 见 {@code PostStatus} 派生表）。</p>
     *
     * @param now   当前时刻（时间基准由任务侧统一取一次）
     * @param limit 单批上限（分批收敛，避免长事务持锁）
     * @return int 实际归档行数
     */
    int archiveExpiredPosts(@Param("now") LocalDateTime now, @Param("limit") int limit);

    /**
     * 删除早于阈值的审计日志（架构 §8 任务 4；保留 180 天为合规下限）。
     *
     * @param threshold 保留阈值（早于它的行被删）
     * @param limit     单批上限
     * @return int 实际删除行数
     */
    int deleteAuditLogsBefore(@Param("threshold") LocalDateTime threshold, @Param("limit") int limit);

    /**
     * 物理删除软删满保留期的收藏记录（架构 §8 任务 6；软删 30 天内供误删恢复）。
     *
     * @param threshold 保留阈值（{@code deleted_at} 早于它的行被物删）
     * @param limit     单批上限
     * @return int 实际删除行数
     */
    int deleteFavoritesBefore(@Param("threshold") LocalDateTime threshold, @Param("limit") int limit);

    /**
     * 取冷静期已满、待清理的用户 ID 列表（架构 §8 任务 7；注销 7 天冷静期）。
     *
     * <p>选取条件为 {@code deactivate_at IS NOT NULL AND deactivate_at <= threshold}——
     * 撤回注销会把 {@code deactivate_at} 清空（「撤回后数据原封不动」，PRD §9.7），
     * 故非空即「仍在注销流程中」，无需另设状态列。</p>
     *
     * @param threshold 冷静期阈值
     * @return {@link List} 待清理 user_id（可能为空）
     */
    List<Long> selectDeactivatingUserIds(@Param("threshold") LocalDateTime threshold);

    /**
     * 按 {@code user_id} 删除全部登录身份行（架构 §8 任务 7 的核心：不是只删一行）。
     *
     * <p>一个账号可能挂多条 {@code user_identity}（Batch1 为 {@code phone}，Batch2 起追加
     * {@code wechat}）；按 id 删只会删掉一行，残留身份会让「已注销」账号被再次登录复活
     * （架构 §8 三条口径说明第 2 条）。</p>
     *
     * @param userIds 待清理用户 ID（非空）
     * @return int 实际删除行数
     */
    int deleteIdentitiesByUserIds(@Param("userIds") List<Long> userIds);

    /**
     * 清空注销用户的实名结果与手机号掩码（架构 §8 任务 7 的「实名结果 + 清空 phone_mask」）。
     *
     * <p>置 {@code NULL} 而非删除 {@code user} 行：账号行仍被 {@code post} 等表引用
     * （帖子保留可追溯），且 {@code uk_id_card_hash} 允许并列 NULL，故置空不破坏唯一约束。
     * {@code phone_mask} 为 {@code NOT NULL} 列，置空串。</p>
     *
     * @param userIds 待清理用户 ID（非空）
     * @return int 实际更新行数
     */
    int clearUserPersonalData(@Param("userIds") List<Long> userIds);

    /**
     * 取超时未 commit 的孤儿媒体（架构 §5.1 第 7 条 + §8 任务 9）。
     *
     * <p>孤儿判定为 {@code post_id IS NULL}：媒体先以孤儿行入库（{@code pending}），
     * commit 时回填 {@code post_id} 并转审核态；因此「超时仍无 {@code post_id}」即
     * 「客户端传完就退出、从未 commit」。</p>
     *
     * @param threshold 超时阈值（{@code created_at} 早于它的孤儿行）
     * @param limit     单批上限
     * @return {@link List} 每行两列 {@code id} / {@code object_key}
     */
    List<Map<String, Object>> selectPendingMedia(@Param("threshold") LocalDateTime threshold,
            @Param("limit") int limit);

    /**
     * 按主键删除媒体登记行（任务 9：清 OSS 对象后删登记）。
     *
     * @param ids 媒体 ID（非空）
     * @return int 实际删除行数
     */
    int deleteMediaByIds(@Param("ids") List<Long> ids);

    /**
     * 取待清理注销用户名下的全部帖子 ID（任务 7 第 4 步：连帖子一并删除）。
     *
     * <p>用户 2026-09-29 裁定「连帖子一并删除」——理由：架构 §8 与数据库设计 §5 都要求
     * 删除注销用户的「联系方式」，而 {@code post.contact_value_enc} 是 NOT NULL 列无法置空；
     * 既然帖子不能失去联系方式列，可行的彻底删除路径就是连同帖子一并删除
     * （个人信息删除义务优先于下架帖的保留期策略）。</p>
     *
     * @param userIds 待清理用户 ID（非空）
     * @return {@link List} 帖子 ID（可能为空）
     */
    List<Long> selectPostIdsByUserIds(@Param("userIds") List<Long> userIds);

    /**
     * 取指定帖子下的媒体登记（含 OSS 对象键），供删帖前清理对象存储。
     *
     * @param postIds 帖子 ID（非空）
     * @return {@link List} 每行两列 {@code id} / {@code object_key}
     */
    List<Map<String, Object>> selectMediaByPostIds(@Param("postIds") List<Long> postIds);

    /**
     * 删除指定帖子下的全部媒体登记行（任务 7 第 4 步的连带清理）。
     *
     * @param postIds 帖子 ID（非空）
     * @return int 实际删除行数
     */
    int deleteMediaByPostIds(@Param("postIds") List<Long> postIds);

    /**
     * 删除该用户名下的全部帖子（任务 7 第 4 步）。
     *
     * @param userIds 待清理用户 ID（非空）
     * @return int 实际删除行数
     */
    int deletePostsByUserIds(@Param("userIds") List<Long> userIds);
}
