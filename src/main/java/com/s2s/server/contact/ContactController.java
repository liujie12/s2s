package com.s2s.server.contact;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimit;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.common.web.ClientIp;
import com.s2s.server.contact.dto.ContactInfo;
import com.s2s.server.contact.dto.ReportRequest;
import com.s2s.server.contact.dto.ReportResult;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 联系域控制器（[128]；详设 §5.5）。
 *
 * <p>职责：承载 contact 域两个 HTTP 入口——{@code GET /posts/{post_id}/contact}
 * （全系统唯一联系方式出口）与 {@code POST /posts/{post_id}/report}（举报）。
 * 返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳，本类不写 {@code ApiResponse}。</p>
 *
 * <p><b>为什么 contact 接口不挂 {@code @RateLimit} 而 report 挂</b>：联系方式拉取是
 * 「五重防护 + 有序链路」（详设 §5.5.1 的 [1]→[9] 次序本身是规格），
 * 注解驱动无法表达「先查冻结、再计日限、再检突发」的层次，故由
 * {@link ContactRateGuard} 在 service 内编排；举报只需一条独立轨
 * （{@code rl:report:uid:...}），注解声明即完整表达。</p>
 *
 * <p><b>两个入口都强制登录</b>：未登录一律 {@code 40101}（不区分接口）。这既是
 * {@code contact_event}/{@code report} 的 {@code NOT NULL} 用户列所必需，也是安全
 * §3 的口径——联系方式的未登录拒绝「使换 IP 无法绕过账号维度上限」。</p>
 */
@RestController
public class ContactController {

    /** X-Device-Id 请求头名（契约三头之一，详设 §3.2）。 */
    private static final String DEVICE_ID_HEADER = "X-Device-Id";

    private final ContactService contactService;

    /**
     * 构造联系域控制器。
     *
     * @param contactService 联系域服务（解密出口与举报落库）
     */
    public ContactController(ContactService contactService) {
        this.contactService = contactService;
    }

    /**
     * 查看完整联系方式（{@code GET /posts/{post_id}/contact}，全系统唯一出口）。
     *
     * @param postId      帖子 ID
     * @param httpRequest 当前请求（取登录态、设备头、客户端 IP）
     * @return {@link ContactInfo}（完整联系方式 + 账号维剩余次数）
     */
    @GetMapping("/posts/{post_id}/contact")
    public ContactInfo getPostContact(@PathVariable("post_id") Long postId,
            HttpServletRequest httpRequest) {
        Long viewerId = requireUserId(httpRequest);
        return contactService.viewContact(viewerId, postId, dimensionsOf(viewerId, httpRequest));
    }

    /**
     * 举报帖子（{@code POST /posts/{post_id}/report}）。
     *
     * @param postId      帖子 ID
     * @param request     举报载荷（{@code reason} 必填且须为契约枚举值）
     * @param httpRequest 当前请求（取登录态）
     * @return {@link ReportResult}（举报 ID + 初始状态）
     */
    @PostMapping("/posts/{post_id}/report")
    @RateLimit(RateLimitTrack.REPORT_UID)
    public ReportResult reportPost(@PathVariable("post_id") Long postId,
            @Valid @RequestBody ReportRequest request,
            HttpServletRequest httpRequest) {
        Long reporterId = requireUserId(httpRequest);
        // 原因白名单校验放在 controller：契约外的值属客户端参数错误（40001），
        // 不能落到 service 的落库路径——那会被 MySQL 的 ENUM 约束拦成 50001
        // （客户端按可重试处理），或非严格模式下静默存空串（举报原因永久丢失）。
        if (!ReportReason.isValid(request.reason())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return contactService.report(reporterId, postId, request);
    }

    /**
     * 组装本次请求的限频维度（账号 + 设备头 + IP + 自然日）。
     *
     * @param viewerId    当前登录用户 ID
     * @param httpRequest 当前请求（设备头与 IP 来源）
     * @return {@link RateLimitEntries.RateLimitDimensions} 五元组
     */
    private RateLimitEntries.RateLimitDimensions dimensionsOf(Long viewerId,
            HttpServletRequest httpRequest) {
        return RateLimitEntries.RateLimitDimensions.of(
                viewerId,
                httpRequest.getHeader(DEVICE_ID_HEADER),
                ClientIp.of(httpRequest),
                RateLimitKeys.today());
    }

    /**
     * 取登录用户 ID，未登录抛 {@code 40101}（范式同 {@code PostController#requireUserId}）。
     *
     * @param request 当前请求
     * @return {@link Long} 登录用户 ID
     * @throws BizException {@code 40101}
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
