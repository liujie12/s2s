package com.s2s.server.post;

import com.s2s.server.common.web.AuthContext;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PostDraft;
import com.s2s.server.post.dto.PrecheckResult;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 发布域控制器（[125]；详设 §5.3.2）。
 *
 * <p>职责：承载 post 域 HTTP 入口——{@code POST /posts/precheck}（发布预检）、
 * {@code POST /posts}（发布帖子）。返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳。</p>
 */
@RestController
public class PostController {

    private final PrecheckService precheckService;
    private final PostService postService;

    /**
     * 构造发布域控制器。
     *
     * @param precheckService 预检服务
     * @param postService     发布服务
     */
    public PostController(PrecheckService precheckService, PostService postService) {
        this.precheckService = precheckService;
        this.postService = postService;
    }

    /**
     * 发布前置校验（不落库）。
     *
     * @param draft       发布草稿（字段可空）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link PrecheckResult}
     */
    @PostMapping("/posts/precheck")
    public PrecheckResult precheckPost(@RequestBody PostDraft draft, HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        return precheckService.precheck(draft, userId);
    }

    /**
     * 发布帖子。
     *
     * @param request     发布载荷
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link PostDetail}
     */
    @PostMapping("/posts")
    public PostDetail createPost(@Valid @RequestBody PostCreateRequest request,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        return postService.createPost(userId, request);
    }
}
