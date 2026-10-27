package com.s2s.server.contact;

import com.s2s.server.common.ratelimit.RateLimit;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 浏览上报接口（openapi {@code POST /posts/{post_id}/view}）。
 *
 * <p>游客可调用：游客以 {@code X-Device-Id} 作为去重键；调用方无需登录。
 * 失败静默、不重试由客户端负责，服务端按人/天幂等。</p>
 */
@RestController
public class PostViewController {

    /** X-Device-Id 请求头名（设备指纹，明确不可信）。 */
    private static final String X_DEVICE_ID_HEADER = "X-Device-Id";

    private final PostViewService postViewService;

    /**
     * 构造浏览上报控制器。
     *
     * @param postViewService 浏览上报服务
     */
    public PostViewController(PostViewService postViewService) {
        this.postViewService = postViewService;
    }

    /**
     * 上报一次详情浏览。
     *
     * @param postId      帖子 ID
     * @param httpRequest 当前请求（取登录态与设备标识）
     */
    @PostMapping("/posts/{post_id}/view")
    @RateLimit({RateLimitTrack.VIEW_REPORT_UID, RateLimitTrack.VIEW_REPORT_DEV,
            RateLimitTrack.VIEW_REPORT_IP})
    public void reportView(@PathVariable("post_id") Long postId,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        postViewService.report(userId, postId, httpRequest.getHeader(X_DEVICE_ID_HEADER));
    }
}
