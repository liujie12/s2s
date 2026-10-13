package com.s2s.server.ops;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.category.CategoryService;
import com.s2s.server.common.constants.NfrTempCategory;
import com.s2s.server.contact.ContactService;
import com.s2s.server.ops.dto.TempCategoryPage;
import com.s2s.server.ops.entity.TempCategoryEntity;
import com.s2s.server.ops.entity.TempCategoryStatEntity;
import com.s2s.server.ops.mapper.TempCategoryMapper;
import com.s2s.server.ops.mapper.TempCategoryStatMapper;
import com.s2s.server.post.PostQueryService;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link TempCategoryService} 单元测试（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p>守四件事：① 创建临时叶子「落分类树 + 落元数据 + 72h 到期」且两步同一 ID；
 * ② 无到期项时零写入；③ 达标 → promoted 且不禁发；④ 未达标 → expired 且禁发；
 * ⑤ 列表把快照并入视图。</p>
 */
class TempCategoryServiceTest {

    /** 临时类目 Mapper（mock）。 */
    private TempCategoryMapper tempCategoryMapper;

    /** 判定快照 Mapper（mock）。 */
    private TempCategoryStatMapper tempCategoryStatMapper;

    /** 分类服务（mock）。 */
    private CategoryService categoryService;

    /** post 域读服务（mock）。 */
    private PostQueryService postQueryService;

    /** contact 域服务（mock）。 */
    private ContactService contactService;

    /** 被测服务。 */
    private TempCategoryService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        tempCategoryMapper = mock(TempCategoryMapper.class);
        tempCategoryStatMapper = mock(TempCategoryStatMapper.class);
        categoryService = mock(CategoryService.class);
        postQueryService = mock(PostQueryService.class);
        contactService = mock(ContactService.class);
        service = new TempCategoryService(tempCategoryMapper, tempCategoryStatMapper,
                categoryService, postQueryService, contactService);
    }

    /**
     * 创建临时叶子：分类树返回的 ID 即元数据行 ID，状态 active、到期 = now + 72h。
     *
     * @return void；断言失败即临时类目与分类树 ID 脱钩或窗口不正确
     */
    @Test
    void createTempLeafLinksCategoryAndSetsWindow() {
        when(categoryService.createLeaf(eq(205), eq("陪诊"), any(), any(), any(), any()))
                .thenReturn(20501);

        LocalDateTime before = LocalDateTime.now();
        Integer leafId = service.createTempLeaf(205, "陪诊", 7L);

        assertThat(leafId).isEqualTo(20501);
        ArgumentCaptor<TempCategoryEntity> captor =
                ArgumentCaptor.forClass(TempCategoryEntity.class);
        verify(tempCategoryMapper).insert(captor.capture());
        TempCategoryEntity saved = captor.getValue();
        assertThat(saved.getId()).isEqualTo(20501);
        assertThat(saved.getL2ParentId()).isEqualTo(205);
        assertThat(saved.getName()).isEqualTo("陪诊");
        assertThat(saved.getStatus()).isEqualTo(TempCategoryService.STATUS_ACTIVE);
        assertThat(saved.getCreatedBy()).isEqualTo(7L);
        assertThat(saved.getExpireAt())
                .isAfterOrEqualTo(before.plus(NfrTempCategory.VALIDATION_WINDOW));
    }

    /**
     * 无到期项 → 返回 0 且不写任何快照/状态。
     *
     * @return void
     */
    @Test
    void settleExpiredWithNoDueRowsWritesNothing() {
        when(tempCategoryMapper.selectList(any())).thenReturn(List.of());

        int settled = service.settleExpired();

        assertThat(settled).isZero();
        verify(tempCategoryStatMapper, never()).insert(any(TempCategoryStatEntity.class));
        verify(tempCategoryMapper, never()).updateById(any(TempCategoryEntity.class));
    }

    /**
     * 达标（发布 ≥3 且联系 ≥5）→ 快照 promoted=1、状态 promoted、不禁发。
     *
     * @return void；断言失败即达标临时类目被误下线
     */
    @Test
    void settlePromotesWhenMeetingThresholds() {
        TempCategoryEntity due = dueRow(20501);
        when(tempCategoryMapper.selectList(any())).thenReturn(List.of(due));
        when(postQueryService.countPublishedByLeafBetween(eq(20501), any(), any()))
                .thenReturn((long) NfrTempCategory.PROMOTE_MIN_PUBLISH);
        when(contactService.countContactsByLeafBetween(eq(20501), any(), any()))
                .thenReturn((long) NfrTempCategory.PROMOTE_MIN_CONTACT);

        int settled = service.settleExpired();

        assertThat(settled).isEqualTo(1);
        ArgumentCaptor<TempCategoryStatEntity> statCaptor =
                ArgumentCaptor.forClass(TempCategoryStatEntity.class);
        verify(tempCategoryStatMapper).insert(statCaptor.capture());
        assertThat(statCaptor.getValue().getPromoted()).isEqualTo(1);
        assertThat(statCaptor.getValue().getPublishCount())
                .isEqualTo(NfrTempCategory.PROMOTE_MIN_PUBLISH);

        ArgumentCaptor<TempCategoryEntity> patchCaptor =
                ArgumentCaptor.forClass(TempCategoryEntity.class);
        verify(tempCategoryMapper).updateById(patchCaptor.capture());
        assertThat(patchCaptor.getValue().getStatus())
                .isEqualTo(TempCategoryService.STATUS_PROMOTED);
        verify(categoryService, never()).updateCategory(anyInt(), any(), any(), any(), any(), any());
    }

    /**
     * 未达标 → 快照 promoted=0、状态 expired、分类树置禁发。
     *
     * @return void；断言失败即未达标临时类目仍可发布
     */
    @Test
    void settleExpiresAndForbidsWhenBelowThresholds() {
        TempCategoryEntity due = dueRow(20502);
        when(tempCategoryMapper.selectList(any())).thenReturn(List.of(due));
        // 发布差 1 条（低于阈值）
        when(postQueryService.countPublishedByLeafBetween(eq(20502), any(), any()))
                .thenReturn((long) NfrTempCategory.PROMOTE_MIN_PUBLISH - 1);
        when(contactService.countContactsByLeafBetween(eq(20502), any(), any()))
                .thenReturn(100L);

        int settled = service.settleExpired();

        assertThat(settled).isEqualTo(1);
        ArgumentCaptor<TempCategoryEntity> patchCaptor =
                ArgumentCaptor.forClass(TempCategoryEntity.class);
        verify(tempCategoryMapper).updateById(patchCaptor.capture());
        assertThat(patchCaptor.getValue().getStatus())
                .isEqualTo(TempCategoryService.STATUS_EXPIRED);
        verify(categoryService).updateCategory(eq(20502), any(), any(), any(), eq(1), any());
    }

    /**
     * 列表把判定快照并入视图（无快照的条目各统计字段为 null）。
     *
     * @return void
     */
    @Test
    void listMergesStats() {
        TempCategoryEntity row = dueRow(20503);
        when(tempCategoryMapper.countByStatus(any())).thenReturn(2L);
        when(tempCategoryMapper.selectPageByStatus(any(), anyInt(), anyInt()))
                .thenReturn(List.of(row));
        TempCategoryStatEntity stat = new TempCategoryStatEntity();
        stat.setTempCategoryId(20503);
        stat.setPublishCount(4);
        stat.setContactCount(6);
        stat.setPromoted(1);
        when(tempCategoryStatMapper.selectBatchIds(any())).thenReturn(List.of(stat));

        TempCategoryPage page = service.list(null, 1, 20);

        assertThat(page.total()).isEqualTo(2L);
        assertThat(page.items()).hasSize(1);
        assertThat(page.items().get(0).publishCount()).isEqualTo(4);
        assertThat(page.items().get(0).contactCount()).isEqualTo(6);
        assertThat(page.items().get(0).promoted()).isEqualTo(1);
    }

    /**
     * 造一条「已到期」的临时类目行（含结算所需的 created_at/expire_at）。
     *
     * @param id 类目 ID
     * @return {@link TempCategoryEntity} 到期行
     */
    private static TempCategoryEntity dueRow(int id) {
        TempCategoryEntity row = new TempCategoryEntity();
        row.setId(id);
        row.setL2ParentId(205);
        row.setName("陪诊");
        row.setStatus(TempCategoryService.STATUS_ACTIVE);
        row.setCreatedAt(LocalDateTime.of(2026, 10, 1, 0, 0));
        row.setExpireAt(LocalDateTime.of(2026, 10, 4, 0, 0));
        return row;
    }
}
