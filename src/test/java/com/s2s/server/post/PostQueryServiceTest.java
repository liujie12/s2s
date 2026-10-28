package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.category.CategoryService;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.FavoriteQueryService;
import com.s2s.server.post.dto.MyPostsResponse;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PostStatusResult;
import com.s2s.server.post.dto.PostStatusUpdateRequest;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMapper;
import com.s2s.server.post.mapper.PostMediaMapper;
import com.s2s.server.post.mapper.PostQueryMapper;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link PostQueryService} 读路径测试（[127]）。
 *
 * <p>覆盖：详情 41001（不存在 / 对他人不可见）、本人看下架帖放行、额度开关 off 短路、
 * 详情出参 contact_mask 恒 null（红线：CryptoFacade 解密唯一调用点在 contact 域）。</p>
 */
class PostQueryServiceTest {

    private PostQueryMapper postQueryMapper;
    private PostMediaMapper postMediaMapper;
    private MediaAssembler mediaAssembler;
    private CategoryService categoryService;
    private SystemConfigService systemConfigService;
    private CertService certService;
    private DetailQuotaGate detailQuotaGate;
    private FavoriteQueryService favoriteQueryService;
    private PostCredentialAssembler credentialAssembler;
    private PostQueryService service;

    @BeforeEach
    void setUp() {
        postQueryMapper = mock(PostQueryMapper.class);
        postMediaMapper = mock(PostMediaMapper.class);
        mediaAssembler = mock(MediaAssembler.class);
        categoryService = mock(CategoryService.class);
        systemConfigService = mock(SystemConfigService.class);
        certService = mock(CertService.class);
        detailQuotaGate = mock(DetailQuotaGate.class);
        favoriteQueryService = mock(FavoriteQueryService.class);
        credentialAssembler = mock(PostCredentialAssembler.class);
        service = new PostQueryService(postQueryMapper, postMediaMapper, mediaAssembler,
                categoryService, systemConfigService, new ObjectMapper(), certService,
                detailQuotaGate, favoriteQueryService, credentialAssembler);
        when(postMediaMapper.selectList(any())).thenReturn(List.of());
        when(systemConfigService.isOn(any())).thenReturn(false);
    }

    /**
     * 构造详情行夹具。
     *
     * @param status       库内状态
     * @param statusReason 进入非 active 路径的归因
     * @return {@link Map} 详情行
     */
    private Map<String, Object> detailRow(String status, Integer statusReason) {
        Map<String, Object> row = new java.util.HashMap<>();
        row.put("id", 100L);
        row.put("user_id", 1L);
        row.put("type", "resource");
        row.put("leaf_category_id", 10101);
        row.put("l2_category_id", 101);
        row.put("title", "标题");
        row.put("price", new BigDecimal("50.00"));
        row.put("price_unit", "小时");
        row.put("description", "描述");
        row.put("template_values", "{\"a\":1}");
        row.put("lng", new BigDecimal("120.15"));
        row.put("lat", new BigDecimal("30.28"));
        row.put("address", "地址");
        row.put("contact_mask", "138****8000");
        row.put("completeness_level", 2);
        row.put("status", status);
        row.put("status_reason", statusReason);
        row.put("created_at", LocalDateTime.of(2026, 9, 1, 12, 0));
        row.put("expire_at", LocalDateTime.of(2026, 9, 8, 12, 0));
        row.put("version", 0L);
        row.put("author_id", 1L);
        row.put("author_nickname", "王师傅");
        row.put("author_avatar_url", null);
        row.put("author_realname_status", "none");
        return row;
    }

    @Test
    void 详情不存在回41001() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(null);
        assertThatThrownBy(() -> service.getDetail(1L, 999L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
    }

    @Test
    void 非本人看下架帖回41001() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("archived", 0));
        assertThatThrownBy(() -> service.getDetail(2L, 100L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
    }

    @Test
    void 本人看自己下架帖放行() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("archived", 0));
        PostDetail detail = service.getDetail(1L, 100L);
        assertThat(detail.id()).isEqualTo(100L);
        assertThat(detail.status()).isEqualTo("offline");
    }

    @Test
    void 详情出参contactMask取发布时落库脱敏值且author白名单() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(categoryService.categoryPath(any())).thenReturn(List.of("生活", "家政", "日常保洁"));
        PostDetail detail = service.getDetail(2L, 100L);
        // [147] DEC-13：详情出参回发布时落库的脱敏值（原为恒 null）
        assertThat(detail.contactMask()).isEqualTo("138****8000");
        assertThat(detail.author().nickname()).isEqualTo("王师傅");
        assertThat(detail.author().qualificationBadges()).isEmpty();
        assertThat(detail.categoryPath()).containsExactly("生活", "家政", "日常保洁");
    }

    @Test
    void 额度开关off短路不抛() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(systemConfigService.isOn(eq("detail_quota_enabled"))).thenReturn(false);
        // 不抛异常即通过
        service.getDetail(2L, 100L);
    }

    @Test
    void 额度开关on且未实名走额度闸() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(systemConfigService.isOn(eq("detail_quota_enabled"))).thenReturn(true);
        when(certService.getRealnameStatus(eq(2L))).thenReturn(CertService.REALNAME_STATUS_NONE);
        service.getDetail(2L, 100L);
        verify(detailQuotaGate).checkAndIncrement(eq(2L), any());
    }

    @Test
    void 额度开关on且已实名跳过额度闸() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(systemConfigService.isOn(eq("detail_quota_enabled"))).thenReturn(true);
        when(certService.getRealnameStatus(eq(2L))).thenReturn(CertService.REALNAME_STATUS_PASSED);
        service.getDetail(2L, 100L);
        verify(detailQuotaGate, never()).checkAndIncrement(any(), any());
    }

    /**
     * 构造「我的发布」列表行夹具（{@code selectMine} 出参形态）。
     *
     * @param status       库内状态
     * @param statusReason 进入非 active 路径的归因（{@code active} 为 {@code null}）
     * @return {@link Map} 列表行
     */
    private Map<String, Object> mineRow(String status, Integer statusReason) {
        Map<String, Object> row = new java.util.HashMap<>();
        row.put("id", 100L);
        row.put("type", "resource");
        row.put("leaf_category_id", 10101);
        row.put("title", "标题");
        row.put("price", new BigDecimal("50.00"));
        row.put("price_unit", "小时");
        row.put("completeness_level", 2);
        row.put("status", status);
        row.put("status_reason", statusReason);
        row.put("created_at", LocalDateTime.of(2026, 9, 1, 12, 0));
        row.put("expire_at", LocalDateTime.of(2026, 9, 8, 12, 0));
        row.put("version", 3L);
        return row;
    }

    @Test
    void 我的发布出参带价格与单位() {
        when(postQueryMapper.countMine(any(), any(), any(), anyBoolean())).thenReturn(1L);
        when(postQueryMapper.selectMine(any(), any(), any(), anyBoolean(), anyInt(), anyInt()))
                .thenReturn(List.of(mineRow("active", null)));

        MyPostsResponse response = service.listMine(1L, null, 1, 20);

        assertThat(response.items()).hasSize(1);
        // 卡片按 PRD §8.3.1 展示价格，缺列会让价格静默丢失（与 [127] 详情价格缺口同源）
        assertThat(response.items().get(0).price()).isEqualByComparingTo("50.00");
        assertThat(response.items().get(0).priceUnit()).isEqualTo("小时");
        assertThat(response.items().get(0).version()).isEqualTo(3L);
    }

    @Test
    void 分页越界被钳制到合法区间() {
        when(postQueryMapper.countMine(any(), any(), any(), anyBoolean())).thenReturn(0L);
        when(postQueryMapper.selectMine(any(), any(), any(), anyBoolean(), anyInt(), anyInt()))
                .thenReturn(List.of());

        service.listMine(1L, null, 0, 9999);

        // page=0 -> 第 1 页（offset 0）；page_size=9999 -> 上限
        verify(postQueryMapper).selectMine(eq(1L), isNull(), isNull(), eq(false), eq(0),
                eq(NfrApi.PAGE_SIZE_MAX));
    }

    @Test
    void 分页非正数取默认值() {
        when(postQueryMapper.countMine(any(), any(), any(), anyBoolean())).thenReturn(0L);
        when(postQueryMapper.selectMine(any(), any(), any(), anyBoolean(), anyInt(), anyInt()))
                .thenReturn(List.of());

        service.listMine(1L, "active", -3, 0);

        // page=-3 -> 第 1 页；page_size=0 -> 默认 20；status=active 走 DB_ACTIVE 筛选
        verify(postQueryMapper).selectMine(eq(1L), eq(List.of(PostStatus.DB_ACTIVE)), eq(List.of()),
                eq(false), eq(0), eq(NfrApi.PAGE_SIZE_DEFAULT));
    }

    @Test
    void 登录用户详情带收藏态且按当前用户查() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(favoriteQueryService.isFavorited(2L, 100L)).thenReturn(true);

        PostDetail detail = service.getDetail(2L, 100L);

        assertThat(detail.favorited()).isTrue();
        verify(favoriteQueryService).isFavorited(2L, 100L);
    }

    @Test
    void 游客详情收藏态为null且不查收藏表() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));

        PostDetail detail = service.getDetail(null, 100L);

        assertThat(detail.favorited()).isNull();
        verify(favoriteQueryService, never()).isFavorited(any(), any());
    }

    @Test
    void 我的发布出参带收藏数与浏览数() {
        when(postQueryMapper.countMine(any(), any(), any(), anyBoolean())).thenReturn(1L);
        when(postQueryMapper.selectMine(any(), any(), any(), anyBoolean(), anyInt(), anyInt()))
                .thenReturn(List.of(mineRow("active", null)));
        when(postQueryMapper.countFavoritesByPost(anyList(), eq(1L)))
                .thenReturn(List.of(Map.of("post_id", 100L, "cnt", 3L)));
        when(postQueryMapper.sumPostViews(anyList()))
                .thenReturn(List.of(Map.of("post_id", 100L, "cnt", 42L)));

        MyPostsResponse response = service.listMine(1L, null, 1, 20);

        assertThat(response.items().get(0).favoriteCount()).isEqualTo(3L);
        assertThat(response.items().get(0).viewCount()).isEqualTo(42L);
    }

    @Test
    void 无收藏无浏览时计数为0而非null() {
        when(postQueryMapper.countMine(any(), any(), any(), anyBoolean())).thenReturn(1L);
        when(postQueryMapper.selectMine(any(), any(), any(), anyBoolean(), anyInt(), anyInt()))
                .thenReturn(List.of(mineRow("active", null)));
        when(postQueryMapper.countFavoritesByPost(anyList(), eq(1L))).thenReturn(List.of());
        when(postQueryMapper.sumPostViews(anyList())).thenReturn(List.of());

        MyPostsResponse response = service.listMine(1L, null, 1, 20);

        // R8：正常返回 0，前端显示「☆ 0」；null 只留给字段缺失的防御分支
        assertThat(response.items().get(0).favoriteCount()).isZero();
        assertThat(response.items().get(0).viewCount()).isZero();
    }
}
