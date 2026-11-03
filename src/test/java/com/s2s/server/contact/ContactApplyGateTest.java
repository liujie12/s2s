package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.IdentityBindingService;
import com.s2s.server.cert.CertService;
import com.s2s.server.chat.ChatCopy;
import com.s2s.server.chat.ContactApplyService;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.contact.mapper.ContactPostMapper;
import com.s2s.server.contact.mapper.ReportMapper;
import com.s2s.server.notify.PushDispatchService;
import com.s2s.server.post.MediaService;
import com.s2s.server.post.PostModerationService;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 需申请帖的取号闸门测试（V30 / 计划 U6；R22 / R24）。
 *
 * <p>守住两件事：未获同意的非发布者被 {@code 40305 + 需申请文案} 拦在三维限频之前
 * （不白耗看号额度）；已同意、发布者本人、无需申请的帖子继续走既有取号链路。</p>
 */
class ContactApplyGateTest {

    /** 帖子发布者。 */
    private static final Long OWNER_ID = 7L;

    /** 申请人 / 取号者。 */
    private static final Long VIEWER_ID = 42L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 1001L;

    private ContactRateGuard rateGuard;
    private ContactPostMapper contactPostMapper;
    private ContactApplyService contactApplyService;
    private ContactService service;

    /**
     * 装配被测对象：闸门链路之外的依赖全部 mock。
     */
    @BeforeEach
    void setUp() {
        rateGuard = mock(ContactRateGuard.class);
        contactPostMapper = mock(ContactPostMapper.class);
        contactApplyService = mock(ContactApplyService.class);
        IdentityBindingService identityBindingService = mock(IdentityBindingService.class);
        service = new ContactService(rateGuard, contactPostMapper, mock(ContactEventMapper.class),
                mock(ReportMapper.class), mock(CryptoFacade.class), mock(AuditLogWriter.class),
                new ObjectMapper(), mock(CertService.class), mock(PostModerationService.class),
                mock(MediaService.class), identityBindingService, contactApplyService,
                mock(PushDispatchService.class));
    }

    /**
     * 需申请 + 非发布者 + 未获同意：{@code 40305} 与专用文案，且不进入限频。
     *
     * @return void；断言失败即未获同意的人可以取号或白耗当日额度
     */
    @Test
    void blocksUnapprovedViewerBeforeRateLimit() {
        when(contactPostMapper.selectApplyGateRow(POST_ID))
                .thenReturn(gateRow(OWNER_ID, "active", 1));
        when(contactApplyService.hasApprovedAccess(POST_ID, VIEWER_ID)).thenReturn(false);

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, POST_ID, dimensions()))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.APPLY_REQUIRED);
                });
        verify(rateGuard, never()).checkDailyLimits(any());
        verify(rateGuard, never()).assertNotFrozen(anyLong(), any());
    }

    /**
     * 已获同意：闸门放行，继续走既有取号链路（此处由限频抛错证明已越过闸门）。
     *
     * @return void；断言失败即已同意的人被误挡在门外
     */
    @Test
    void allowsApprovedViewer() {
        when(contactPostMapper.selectApplyGateRow(POST_ID))
                .thenReturn(gateRow(OWNER_ID, "active", 1));
        when(contactApplyService.hasApprovedAccess(POST_ID, VIEWER_ID)).thenReturn(true);
        when(contactPostMapper.selectContactRow(POST_ID)).thenReturn(null);

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, POST_ID, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(rateGuard).checkDailyLimits(any());
    }

    /**
     * 发布者本人：不受申请闸门约束。
     *
     * @return void；断言失败即发布者看自己的号码也要审批
     */
    @Test
    void ownerPassesGate() {
        when(contactPostMapper.selectApplyGateRow(POST_ID))
                .thenReturn(gateRow(OWNER_ID, "active", 1));
        when(contactPostMapper.selectContactRow(POST_ID)).thenReturn(null);

        assertThatThrownBy(() -> service.viewContact(OWNER_ID, POST_ID, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(contactApplyService, never()).hasApprovedAccess(any(), any());
        verify(rateGuard).checkDailyLimits(any());
    }

    /**
     * 无需申请的帖子：闸门不生效（维持既有「一键取号」）。
     *
     * @return void；断言失败即未勾选的帖子也要先审批（R25 被破坏）
     */
    @Test
    void flatPostSkipsGate() {
        when(contactPostMapper.selectApplyGateRow(POST_ID))
                .thenReturn(gateRow(OWNER_ID, "active", 0));
        when(contactPostMapper.selectContactRow(POST_ID)).thenReturn(null);

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, POST_ID, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(contactApplyService, never()).hasApprovedAccess(any(), any());
        verify(rateGuard).checkDailyLimits(any());
    }

    /**
     * 帖子已下架：闸门跳过，沿用既有「限频 → 可见性」链路。
     *
     * @return void；断言失败即下架帖的状态差异会在限频之前泄露
     */
    @Test
    void gonePostSkipsGate() {
        when(contactPostMapper.selectApplyGateRow(POST_ID))
                .thenReturn(gateRow(OWNER_ID, "archived", 1));

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, POST_ID, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(rateGuard).checkDailyLimits(any());
        verify(contactApplyService, never()).hasApprovedAccess(any(), any());
    }

    /**
     * 构造闸门查询行。
     *
     * @param ownerId       发布者 ID
     * @param status        库内状态
     * @param applyRequired 需申请标记（1=是）
     * @return {@link Map} 三列行
     */
    private Map<String, Object> gateRow(Long ownerId, String status, int applyRequired) {
        Map<String, Object> row = new HashMap<>();
        row.put("user_id", ownerId);
        row.put("status", status);
        row.put("contact_apply_required", applyRequired);
        return row;
    }

    /**
     * 构造限频维度（账号维以 {@link #VIEWER_ID} 计）。
     *
     * @return {@link RateLimitEntries.RateLimitDimensions} 测试维度
     */
    private RateLimitEntries.RateLimitDimensions dimensions() {
        return RateLimitEntries.RateLimitDimensions.of(VIEWER_ID, "device-1", "127.0.0.1",
                LocalDate.of(2026, 10, 31));
    }
}
