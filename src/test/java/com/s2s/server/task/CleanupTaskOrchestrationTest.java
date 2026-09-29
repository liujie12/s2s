package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

import com.s2s.server.post.OssClient;
import com.s2s.server.task.mapper.TaskMapper;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * 两个高危清理任务的编排测试（[129] P4）：注销清理（#7）与媒体孤儿清理（#9）。
 *
 * <p>选这两个来测的理由是它们各自的失败形态都是<b>破坏性且不可逆</b>的：</p>
 * <ul>
 *   <li>#7 若在「无待清理用户」时仍执行删除，会把条件落成空集以外的范围（最坏是全表）；</li>
 *   <li>#9 若在 OSS 删除失败时仍删登记行，桶里的对象将再无任何线索可追溯（登记行是唯一凭据），
 *       对象永久滞留并持续占盘。</li>
 * </ul>
 *
 * <p>纯单元测试：Mapper 与 OSS 客户端均以 Mockito 替身注入，不连库、不碰网络。</p>
 */
class CleanupTaskOrchestrationTest {

    private TaskMapper taskMapper;
    private OssClient ossClient;

    /**
     * 装配替身。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        taskMapper = mock(TaskMapper.class);
        ossClient = mock(OssClient.class);
    }

    /**
     * 注销清理：无待清理用户时不得触达任何删除语句。
     *
     * @return void；断言失败即「无数据也会删」——最坏形态是全表删除
     */
    @Test
    @DisplayName("#7 无待清理用户 → 不触达删除与更新")
    void deactivateCleanupNoopWhenNothingDue() {
        when(taskMapper.selectDeactivatingUserIds(any())).thenReturn(List.of());

        new DeactivateCleanupTask(taskMapper, ossClient).purgeDeactivatedUsers();

        verify(taskMapper).selectDeactivatingUserIds(any());
        // 除查询外不得有任何交互：无数据时的删除会退化为「按空集合执行」，最坏形态是全表删除
        verifyNoMoreInteractions(taskMapper);
        verifyNoInteractions(ossClient);
    }

    /**
     * 注销清理：有待清理用户、名下无帖子时，按 user_id 完成身份行删除与实名/掩码清空。
     *
     * @return void；断言失败即清理未按 user_id 粒度执行
     */
    @Test
    @DisplayName("#7 有待清理用户 → 按 user_id 删身份行 + 清实名与掩码")
    void deactivateCleanupPurgesByUserId() {
        List<Long> userIds = List.of(11L, 22L);
        when(taskMapper.selectDeactivatingUserIds(any())).thenReturn(userIds);
        when(taskMapper.selectPostIdsByUserIds(userIds)).thenReturn(List.of());
        when(taskMapper.deletePostsByUserIds(userIds)).thenReturn(0);
        when(taskMapper.deleteIdentitiesByUserIds(userIds)).thenReturn(2);
        when(taskMapper.clearUserPersonalData(userIds)).thenReturn(2);

        new DeactivateCleanupTask(taskMapper, ossClient).purgeDeactivatedUsers();

        verify(taskMapper).deleteIdentitiesByUserIds(userIds);
        verify(taskMapper).clearUserPersonalData(userIds);
        verifyNoInteractions(ossClient);
    }

    /**
     * 注销清理：名下有帖子时连帖带媒体一并删除（用户 2026-09-29 裁定「连帖子一并删除」）。
     *
     * @return void；断言失败即联系方式的加密列随帖子残留，注销承诺未履行完毕
     */
    @Test
    @DisplayName("#7 名下有帖子 → 删 OSS 对象 + 删媒体登记 + 删帖子")
    void deactivateCleanupDeletesPostsAndMedia() {
        List<Long> userIds = List.of(11L);
        List<Long> postIds = List.of(101L, 102L);
        when(taskMapper.selectDeactivatingUserIds(any())).thenReturn(userIds);
        when(taskMapper.selectPostIdsByUserIds(userIds)).thenReturn(postIds);
        when(taskMapper.selectMediaByPostIds(postIds)).thenReturn(List.of(media(9L, "post/9.jpg")));
        when(taskMapper.deleteMediaByPostIds(postIds)).thenReturn(1);
        when(taskMapper.deletePostsByUserIds(userIds)).thenReturn(2);

        new DeactivateCleanupTask(taskMapper, ossClient).purgeDeactivatedUsers();

        verify(ossClient).deleteObject("post/9.jpg");
        verify(taskMapper).deleteMediaByPostIds(postIds);
        verify(taskMapper).deletePostsByUserIds(userIds);
    }

    /**
     * 媒体孤儿清理：无孤儿时不触达 OSS 与删除。
     *
     * @return void；断言失败即空批仍发网络请求
     */
    @Test
    @DisplayName("#9 无孤儿 → 不删登记、不碰 OSS")
    void mediaCleanupNoopWhenNoOrphan() {
        when(taskMapper.selectPendingMedia(any(), anyInt())).thenReturn(List.of());

        new MediaOrphanCleanupTask(taskMapper, ossClient).cleanupOrphanMedia();

        verifyNoInteractions(ossClient);
        verify(taskMapper, never()).deleteMediaByIds(anyList());
    }

    /**
     * 媒体孤儿清理：OSS 删除失败的行必须保留登记（登记行是找回对象的唯一凭据）。
     *
     * @return void；断言失败即对象会变成永久孤儿
     */
    @Test
    @DisplayName("#9 OSS 删除失败 → 不删该行登记（保留待重试）")
    void mediaCleanupKeepsRowWhenOssDeletionFails() {
        when(taskMapper.selectPendingMedia(any(), anyInt()))
                .thenReturn(List.of(media(1L, "orphan/a.jpg")));
        org.mockito.Mockito.doThrow(new IllegalStateException("OSS 不可用"))
                .when(ossClient).deleteObject("orphan/a.jpg");

        new MediaOrphanCleanupTask(taskMapper, ossClient).cleanupOrphanMedia();

        verify(taskMapper, never()).deleteMediaByIds(anyList());
    }

    /**
     * 媒体孤儿清理：混合批次只删 OSS 删除成功的那部分登记行（且不得重复取同一批导致死循环）。
     *
     * @return void；断言失败即失败行被误删或本批未收敛
     */
    @Test
    @DisplayName("#9 混合批次 → 只删成功的登记行")
    void mediaCleanupDeletesOnlySucceededRows() {
        when(taskMapper.selectPendingMedia(any(), anyInt()))
                .thenReturn(List.of(media(1L, "orphan/ok.jpg"), media(2L, "orphan/bad.jpg")));
        org.mockito.Mockito.doThrow(new IllegalStateException("OSS 不可用"))
                .when(ossClient).deleteObject("orphan/bad.jpg");
        when(taskMapper.deleteMediaByIds(anyList())).thenReturn(1);

        new MediaOrphanCleanupTask(taskMapper, ossClient).cleanupOrphanMedia();

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<Long>> captor = ArgumentCaptor.forClass(List.class);
        verify(taskMapper).deleteMediaByIds(captor.capture());
        assertThat(captor.getValue()).containsExactly(1L);
    }

    /**
     * 构造一行媒体登记夹具（列名与 {@code TaskMapper.selectPendingMedia} 出参一致）。
     *
     * @param id        媒体 ID
     * @param objectKey OSS 对象键
     * @return {@link Map} 行数据
     */
    private static Map<String, Object> media(Long id, String objectKey) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("id", id);
        row.put("object_key", objectKey);
        return row;
    }
}
