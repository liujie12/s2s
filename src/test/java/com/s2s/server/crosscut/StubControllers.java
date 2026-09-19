package com.s2s.server.crosscut;

import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.ratelimit.RateLimit;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 横切链集成测试专用 stub controller（[122] U7；包名 crosscut 为测试专用，不进 main）。
 *
 * <p>提供三类接口供集成测试组装整条横切链断言：
 * <ul>
 *   <li>{@link #limitedIdempotent()} —— 同时标注 {@code @RateLimit}（CONTACT_UID）与
 *       {@code @Idempotent}，用于验证「限流先于幂等」链序（超限时先返 429 而非幂等缺键 40001）；</li>
 *   <li>{@link #idempotentOnly()} —— 仅 {@code @Idempotent}，用于验证幂等重放；</li>
 *   <li>{@link #plain()} —— 无注解，用于验证全链 request_id 与成功套壳。</li>
 * </ul>
 *
 * <p>返回类型统一 {@link Map}：ResponseBodyWrapper 会套壳为 {@code ApiResponse}，
 * data 字段为 Map 的 JSON 序列化，便于断言信封形态。
 */
@RestController
public class StubControllers {

    /**
     * 同时标注限频（账号维 CONTACT_UID，30/d）与幂等的写接口——
     * 用于「限流先于幂等」链序断言（超限先返 429，不落到幂等缺键 40001）。
     *
     * @return {@link Map} 业务负载（测试固定值）
     */
    @RateLimit({RateLimitTrack.CONTACT_UID})
    @Idempotent
    @PostMapping("/stub/limited-idempotent")
    public Map<String, Object> limitedIdempotent() {
        return Map.of("ok", true);
    }

    /**
     * 仅幂等标注的写接口——用于幂等重放断言（SETNX 失败 + 轮询读到缓存原文）。
     *
     * @return {@link Map} 业务负载（测试固定值）
     */
    @Idempotent
    @PostMapping("/stub/idempotent-only")
    public Map<String, Object> idempotentOnly() {
        return Map.of("created", 1);
    }

    /**
     * 无注解的读接口——用于全链 request_id 与成功套壳断言。
     *
     * @return {@link Map} 业务负载（测试固定值）
     */
    @GetMapping("/stub/plain")
    public Map<String, Object> plain() {
        return Map.of("ping", "pong");
    }
}