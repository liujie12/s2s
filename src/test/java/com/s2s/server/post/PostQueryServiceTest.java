package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.category.CategoryService;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
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
    private PostQueryService service;

    @BeforeEach
    void setUp() {
        postQueryMapper = mock(PostQueryMapper.class);
        postMediaMapper = mock(PostMediaMapper.class);
        mediaAssembler = mock(MediaAssembler.class);
        categoryService = mock(CategoryService.class);
        systemConfigService = mock(SystemConfigService.class);
        service = new PostQueryService(postQueryMapper, postMediaMapper, mediaAssembler,
                categoryService, systemConfigService, new ObjectMapper());
        when(postMediaMapper.selectList(any())).thenReturn(List.of());
        when(systemConfigService.isOn(any())).thenReturn(false);
    }

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
    void 详情出参contactMask恒null且author白名单() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(categoryService.categoryPath(any())).thenReturn(List.of("生活", "家政", "日常保洁"));
        PostDetail detail = service.getDetail(2L, 100L);
        assertThat(detail.contactMask()).isNull();
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
    void 额度开关on且未实名failFast() {
        when(postQueryMapper.selectDetailRow(any())).thenReturn(detailRow("active", null));
        when(systemConfigService.isOn(eq("detail_quota_enabled"))).thenReturn(true);
        assertThatThrownBy(() -> service.getDetail(2L, 100L))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("detail_quota_enabled");
    }
}
