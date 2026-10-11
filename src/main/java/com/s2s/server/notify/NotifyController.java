package com.s2s.server.notify;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.notify.dto.NotificationReadRequest;
import com.s2s.server.notify.dto.NotificationReadResult;
import com.s2s.server.notify.dto.NotificationsResponse;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 通知域控制器（[129]/[B2-11]；详设 §5.6；openapi {@code GET /notifications}、
 * {@code POST /notifications/read}）。
 *
 * <p><b>强制登录态</b>：通知是「发给谁」的强归属数据，未登录 → {@code 40101}
 * （照 contact / track 域的 {@code requireUserId} 写法）。用户标识只取登录态，
 * 不接受任何形式的入参指定。</p>
 *
 * <p><b>无限频注解</b>：详设 §3.4 的键表 11 行无通知轨，本接口为纯读且数据量按用户收敛，
 * 不新造轨（「不新增错误码 / 不自创口径」）。</p>
 *
 * <p><b>返回体不手写套壳</b>：返回 DTO 由 {@code ResponseBodyWrapper} 统一包装为
 * {@code data}；异常一律 {@link BizException}。</p>
 */
@RestController
public class NotifyController {

    private final NotifyService notifyService;

    /**
     * 构造通知域控制器。
     *
     * @param notifyService 通知读服务
     */
    public NotifyController(NotifyService notifyService) {
        this.notifyService = notifyService;
    }

    /**
     * 拉取通知列表（分页 + 类型筛选）。
     *
     * @param type        类型筛选（{@code system}/{@code interaction}/{@code cert}，缺省全部）
     * @param page        页码（从 1 起，缺省 1）
     * @param pageSize    每页条数（缺省 {@code NfrApi.PAGE_SIZE_DEFAULT}）
     * @param httpRequest 当前请求（取登录态）
     * @return {@link NotificationsResponse}
     * @throws BizException {@code 40101} 未登录 / {@code 40001} 类型参数非法
     */
    @GetMapping("/notifications")
    public NotificationsResponse listNotifications(
            @RequestParam(required = false) String type,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return notifyService.list(userId, type, page, pageSize);
    }

    /**
     * 标记通知已读（全部或按 id）。
     *
     * @param request     请求体；{@code null} 或 {@code ids} 为空 = 全部已读
     * @param httpRequest 当前请求（取登录态）
     * @return {@link NotificationReadResult}
     * @throws BizException {@code 40101} 未登录
     */
    @PostMapping("/notifications/read")
    public NotificationReadResult markNotificationsRead(
            @RequestBody(required = false) NotificationReadRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return notifyService.markRead(userId, request == null ? null : request.ids());
    }

    /**
     * 取登录用户 ID，未登录抛 {@code 40101}（范式同 {@code ContactController#requireUserId}）。
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
