package com.s2s.server.ai;

import com.s2s.server.ai.dto.AiParseRequest;
import com.s2s.server.ai.dto.AiParseResult;
import com.s2s.server.ai.dto.AiQuota;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * AI 智能发布控制器（B2-4；openapi 分组四）。
 *
 * <p>职责：承载 {@code POST /ai/publish/parse}（图/语音/文本 → 四件套猜测）与
 * {@code GET /ai/publish/quota}（今日配额查询）。返回 DTO 由 {@code ResponseBodyWrapper}
 * 统一套壳（不手写 ApiResponse）。两个端点均需登录（未登录 {@code 40101}）。</p>
 */
@RestController
@RequestMapping("/ai/publish")
public class AiController {

    private final AiParseService aiParseService;
    private final AiQuotaService aiQuotaService;

    /**
     * 构造 AI 控制器。
     *
     * @param aiParseService 解析服务（四步管线）
     * @param aiQuotaService 配额档位服务
     */
    public AiController(AiParseService aiParseService, AiQuotaService aiQuotaService) {
        this.aiParseService = aiParseService;
        this.aiQuotaService = aiQuotaService;
    }

    /**
     * AI 智能发布解析（四模式共用）。
     *
     * <p>{@code @Idempotent}：同一次解析重试不重复打上游（登录态键维度）。</p>
     *
     * @param request     解析入参（至少一项输入非空）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link AiParseResult}
     */
    @PostMapping("/parse")
    @Idempotent
    public AiParseResult parse(@Valid @RequestBody AiParseRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return aiParseService.parse(userId, request);
    }

    /**
     * 查询今日 AI 配额（只读，不扣减）。
     *
     * @param completenessLevel 当前草稿完整度档（query {@code completeness_level}，可空，缺省 0）
     * @param leafCategoryId    当前叶子类目 ID（query {@code leaf_category_id}，可空，高敏 +10）
     * @param httpRequest       当前请求（取登录用户 ID）
     * @return {@link AiQuota}
     */
    @GetMapping("/quota")
    public AiQuota quota(
            @RequestParam(name = "completeness_level", required = false) Integer completenessLevel,
            @RequestParam(name = "leaf_category_id", required = false) Integer leafCategoryId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        int limit = aiQuotaService.resolveLimit(userId, completenessLevel, leafCategoryId);
        return aiQuotaService.snapshot(userId, limit);
    }

    /**
     * 取当前登录用户 ID，未登录抛 {@code 40101}。
     *
     * @param request 当前请求
     * @return {@link Long} 用户 ID
     * @throws BizException 未登录 → {@code 40101}
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
