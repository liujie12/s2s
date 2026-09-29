package com.s2s.server.track.controller;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimit;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.track.dto.TrackEventsRequest;
import com.s2s.server.track.dto.TrackEventsResponse;
import com.s2s.server.track.service.TrackService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 埋点域控制器（[129]；详设 §5.8）。
 *
 * <p><b>为什么限频走注解、落库走 service</b>：契约与详设 §3.4 第 9 行给了独立轨
 * {@code rl:track:uid:{userId}:1m}（60 请求/min → {@code 42906}），该轨只依赖账号维度、
 * 无层次编排需求，故由 {@code @RateLimit(RateLimitTrack.TRACK_UID)} 声明即完整表达；
 * 而批次上限、归月表、兜底降级等次序敏感逻辑落在 {@link TrackService}。</p>
 *
 * <p><b>返回体不手写套壳</b>：返回 DTO 由 {@code ResponseBodyWrapper} 统一包装为
 * {@code data}，本类不构造 {@code ApiResponse}；异常一律 {@link BizException}，
 * {@code Retry-After} 仅由 {@code GlobalExceptionHandler} 写入。</p>
 *
 * <p><b>强制登录态</b>：未登录 → {@code 40101}（照 contact 域 {@code requireUserId} 写法）。
 * 埋点 {@code user_id} 只取登录态，不信任请求体中的任何用户标识。</p>
 */
@RestController
public class TrackController {

    /** X-Device-Id 请求头名（契约三头之一，详设 §3.2）。 */
    private static final String DEVICE_ID_HEADER = "X-Device-Id";

    private final TrackService trackService;

    /**
     * 构造埋点域控制器。
     *
     * @param trackService 埋点上报服务（归月表落库与降级）
     */
    public TrackController(TrackService trackService) {
        this.trackService = trackService;
    }

    /**
     * 上报一批埋点事件（{@code POST /track/events}）。
     *
     * @param request     上报请求（{@code events} 非空；字段校验由 {@code @Valid} 完成）
     * @param httpRequest 当前请求（取登录态与设备头）
     * @return {@link TrackEventsResponse} 实际入库事件数
     * @throws BizException {@code 40101} 未登录 / {@code 42906} 批次超限或限频
     */
    @PostMapping("/track/events")
    @RateLimit(RateLimitTrack.TRACK_UID)
    public TrackEventsResponse reportEvents(@Valid @RequestBody TrackEventsRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        String deviceId = httpRequest.getHeader(DEVICE_ID_HEADER);
        return trackService.accept(userId, deviceId, request);
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
