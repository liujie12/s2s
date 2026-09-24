package com.s2s.server.post;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.ratelimit.RateLimit;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.post.dto.MyPostsResponse;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PostDraft;
import com.s2s.server.post.dto.PostStatusResult;
import com.s2s.server.post.dto.PostStatusUpdateRequest;
import com.s2s.server.post.dto.PrecheckResult;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 发布域控制器（[125] 发布链 + [127] 读路径与状态变更；详设 §5.3）。
 *
 * <p>职责：承载 post 域 HTTP 入口——{@code POST /posts/precheck}（发布预检）、
 * {@code POST /posts}（发布帖子）、{@code GET /posts/{post_id}}（详情，游客可读）、
 * {@code PATCH /posts/{post_id}/status}（下架/重新上架/延期）、
 * {@code GET /posts/mine}（我的发布）。返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳。</p>
 *
 * <p><b>路径优先级</b>：{@code GET /posts/mine} 与 {@code GET /posts/{post_id}} 前缀重合，
 * Spring 的路径匹配对字面段优先于变量段，故 {@code mine} 不会落到 {@code post_id} 上。</p>
 */
@RestController
public class PostController {

    private final PrecheckService precheckService;
    private final PostService postService;
    private final PostQueryService postQueryService;

    /**
     * 构造发布域控制器。
     *
     * @param precheckService  预检服务
     * @param postService      写服务（发布 / 状态变更）
     * @param postQueryService 读服务（详情 / 我的发布）
     */
    public PostController(PrecheckService precheckService,
            PostService postService,
            PostQueryService postQueryService) {
        this.precheckService = precheckService;
        this.postService = postService;
        this.postQueryService = postQueryService;
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
     * <p><b>[125] 遗留修复（[127] 一并落地）</b>：openapi 本操作声明了
     * {@code Idempotency-Key}（l.744），但 [125] 落地时漏标 {@code @Idempotent}，
     * 幂等判定实际未生效；此处补标（登录态键维度，默认 {@code anonymous=false}）。</p>
     *
     * @param request     发布载荷
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link PostDetail}
     */
    @PostMapping("/posts")
    @Idempotent
    public PostDetail createPost(@Valid @RequestBody PostCreateRequest request,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        return postService.createPost(userId, request);
    }

    /**
     * 查帖子详情（未登录可只读）。
     *
     * <p>游客限频 42907：{@code @RateLimit} 声明设备轨与 IP 轨，{@code RateLimitInterceptor}
     * 只在未登录态计数（详设 §3.4 纪律 5；链序保证鉴权先于限流）。已登录用户不受此限。</p>
     *
     * @param postId      帖子 ID
     * @param httpRequest 当前请求（取登录用户 ID，游客为 null）
     * @return {@link PostDetail}
     */
    @GetMapping("/posts/{post_id}")
    @RateLimit({RateLimitTrack.GUEST_DETAIL_DEV, RateLimitTrack.GUEST_DETAIL_IP})
    public PostDetail getPostDetail(@PathVariable("post_id") Long postId,
            HttpServletRequest httpRequest) {
        Long viewerId = AuthContext.currentUserId(httpRequest);
        return postQueryService.getDetail(viewerId, postId);
    }

    /**
     * 变更帖子状态（下架 / 重新上架 / 延期）。
     *
     * @param postId      帖子 ID
     * @param request     变更入参（{@code action} + {@code version} 必带）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link PostStatusResult}
     */
    @PatchMapping("/posts/{post_id}/status")
    @Idempotent
    public PostStatusResult updatePostStatus(@PathVariable("post_id") Long postId,
            @Valid @RequestBody PostStatusUpdateRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return postService.updateStatus(userId, postId, request);
    }

    /**
     * 我发布的帖子列表。
     *
     * @param status      状态筛选（API 值；缺省返回全部）
     * @param page        页码（缺省 1）
     * @param pageSize    每页条数（缺省 {@code NfrApi.PAGE_SIZE_DEFAULT}）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link MyPostsResponse}
     */
    @GetMapping("/posts/mine")
    public MyPostsResponse listMyPosts(
            @RequestParam(value = "status", required = false) String status,
            @RequestParam(value = "page", required = false) Integer page,
            @RequestParam(value = "page_size", required = false) Integer pageSize,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return postQueryService.listMine(userId, status, page, pageSize);
    }

    /**
     * 取登录用户 ID，未登录抛 {@code 40101}（范式同 {@code UserController#requireUserId}）。
     *
     * @param request 当前请求
     * @return {@link Long} 登录用户 ID
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
