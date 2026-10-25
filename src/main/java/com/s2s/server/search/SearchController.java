package com.s2s.server.search;

import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.search.dto.SearchResolveRequest;
import com.s2s.server.search.dto.SearchResolveResult;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 语义搜索控制器（地图语音语义搜索 U3；openapi 分组「搜索」）。
 *
 * <p>职责：承载 {@code POST /search/resolve}，把文字或语音解析成槽位卡。
 * 游客可访问（无 {@code Authorization} 头即游客态，见 {@code AuthInterceptor}），
 * 因此不能像 {@code AiController} 那样强制 {@code requireUserId}。</p>
 *
 * <p>{@code @Idempotent(anonymous = true)}：同一句话的重试不重复打上游 ASR/AI。
 * 匿名键维度为 {@code idem:dev:{X-Device-Id}:{key}}（缺设备头降级
 * {@code idem:anon:{key}}），登录用户同样可用（无用户维度要求）。</p>
 */
@RestController
@RequestMapping("/search")
public class SearchController {

    private final SearchResolveService searchResolveService;

    /**
     * 构造搜索控制器。
     *
     * @param searchResolveService 语义解析服务
     */
    public SearchController(SearchResolveService searchResolveService) {
        this.searchResolveService = searchResolveService;
    }

    /**
     * 解析一句话搜索意图（文字/语音）。
     *
     * @param request     解析入参（至少文字或语音之一非空）
     * @param httpRequest 当前请求（取登录用户 ID，游客为 null）
     * @return {@link SearchResolveResult} 槽位卡
     */
    @PostMapping("/resolve")
    @Idempotent(anonymous = true)
    public SearchResolveResult resolve(@Valid @RequestBody SearchResolveRequest request,
            HttpServletRequest httpRequest) {
        return searchResolveService.resolve(AuthContext.currentUserId(httpRequest), request);
    }
}
