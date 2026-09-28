package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.contact.dto.ContactInfo;
import com.s2s.server.contact.dto.ReportRequest;
import com.s2s.server.contact.dto.ReportResult;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

/**
 * {@link ContactController} 测试（[128]）。
 *
 * <p>覆盖两条入口级纪律与一条参数校验：
 * ① 两个入口未登录一律 {@code 40101}（安全 §3：未登录拒绝使换 IP 无法绕过账号维上限）；
 * ② 举报 {@code reason} 非契约枚举值 → {@code 40001}（不能落到落库路径被 MySQL
 * ENUM 约束拦成 50001，或非严格模式下静默存空串）；
 * ③ 合法入参向 service 的委托（含登录态与维度透传）。</p>
 */
class ContactControllerTest {

    /** 测试用登录用户 ID。 */
    private static final Long USER_ID = 42L;

    /** 测试用帖子 ID。 */
    private static final Long POST_ID = 1001L;

    private final ContactService contactService = mock(ContactService.class);
    private final ContactController controller = new ContactController(contactService);

    /**
     * 查看联系方式：未登录 → {@code 40101}，且不触达 service
     * （未登录请求不应消耗限频计数，也不该进入解密链路）。
     *
     * @return void；断言失败即游客可触发解密或消耗配额
     */
    @Test
    void viewContactRequiresLogin() {
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThatThrownBy(() -> controller.getPostContact(POST_ID, request))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);

        verify(contactService, never()).viewContact(anyLong(), anyLong(), any());
    }

    /**
     * 查看联系方式：已登录 → 委托 service，并透传登录用户与四维限频维度
     * （设备头取自 {@code X-Device-Id}，IP 取自 {@code ClientIp}）。
     *
     * @return void；断言失败即维度未透传，IP/设备轨会静默失效
     */
    @Test
    void viewContactDelegatesWithDimensions() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        AuthContext.setUserId(request, USER_ID);
        request.addHeader("X-Device-Id", "9f8b1c2d-3e4f-4a5b-8c7d-6e5f4a3b2c1d");
        request.setRemoteAddr("10.0.0.8");
        when(contactService.viewContact(eq(USER_ID), eq(POST_ID), any()))
                .thenReturn(new ContactInfo("phone", "13800138000", 29));

        ContactInfo info = controller.getPostContact(POST_ID, request);

        assertThat(info.contactValue()).isEqualTo("13800138000");

        org.mockito.ArgumentCaptor<RateLimitEntries.RateLimitDimensions> captor =
                org.mockito.ArgumentCaptor.forClass(RateLimitEntries.RateLimitDimensions.class);
        verify(contactService).viewContact(eq(USER_ID), eq(POST_ID), captor.capture());
        RateLimitEntries.RateLimitDimensions dimensions = captor.getValue();
        assertThat(dimensions.userId()).isEqualTo(USER_ID);
        assertThat(dimensions.deviceId()).isEqualTo("9f8b1c2d-3e4f-4a5b-8c7d-6e5f4a3b2c1d");
        assertThat(dimensions.deviceIdValid()).isTrue();
        assertThat(dimensions.ip()).isEqualTo("10.0.0.8");
    }

    /**
     * 举报：未登录 → {@code 40101}。
     *
     * @return void；断言失败即匿名举报可行（reporter_id 无法落库）
     */
    @Test
    void reportRequiresLogin() {
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThatThrownBy(() -> controller.reportPost(POST_ID,
                new ReportRequest("fraud", null, null), request))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
    }

    /**
     * 举报原因不在契约枚举内 → {@code 40001}，且不落库。
     *
     * @return void；断言失败即非法原因进入落库路径（50001 假故障或静默丢原因）
     */
    @Test
    void reportRejectsUnknownReason() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        AuthContext.setUserId(request, USER_ID);

        assertThatThrownBy(() -> controller.reportPost(POST_ID,
                new ReportRequest("spam", null, null), request))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);

        verify(contactService, never()).report(anyLong(), anyLong(), any());
    }

    /**
     * 举报：合法原因 → 委托 service。
     *
     * @return void；断言失败即合法举报被误拦
     */
    @Test
    void reportDelegatesWhenReasonValid() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        AuthContext.setUserId(request, USER_ID);
        when(contactService.report(USER_ID, POST_ID, new ReportRequest("other", null, null)))
                .thenReturn(new ReportResult(88L, "pending"));

        ReportResult result = controller.reportPost(POST_ID,
                new ReportRequest("other", null, null), request);

        assertThat(result.reportId()).isEqualTo(88L);
    }
}
