package com.s2s.server.common.idempotency;

import com.s2s.server.common.constants.NfrApi;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.MediaType;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;

/**
 * 幂等响应捕获 Filter（[122] U5；详设 §3.3；架构评审 P0 修正的响应体捕获层）。
 *
 * <p><b>为什么捕获必须在本 Filter 层而非拦截器 preHandle</b>（架构评审 P0）：
 * {@code ContentCachingResponseWrapper} 是 Servlet Filter 层组件，必须由 Filter
 * 包装 response 后把同一引用沿链传下去才能捕获 handler/advice 写出的字节。
 * 拦截器 {@code preHandle} 里的包装副本 handler 不可见（DispatcherServlet 向整条链
 * 传的是它自己那一份 response 引用），缓存恒空——故本 Filter 在 {@code RequestIdFilter}
 * 之后包装 response，幂等判定仍由 {@link IdempotencyInterceptor} 以纯判定件形态完成。
 *
 * <p>本 Filter 只做三件出口动作（依据拦截器写入的请求属性分流）：
 * <ol>
 *   <li><b>重放者</b>（{@link IdempotencyInterceptor#ATTR_REPLAY_BODY} 非空）：
 *       把首次完成 JSON 原样写出（含首次 request_id），不进 controller；</li>
 *   <li><b>执行者</b>（{@link IdempotencyInterceptor#ATTR_REDIS_KEY} 非空）：
 *       读响应状态——2xx 则把响应体（完整信封 JSON）SET 覆盖占位键，非 2xx 则 DEL
 *       占位键（同 Key 重放重新执行）；</li>
 *   <li><b>无幂等处理</b>（两属性皆空）：仅 {@code copyBodyToResponse()}。</li>
 * </ol>
 *
 * <p><b>必调 {@code copyBodyToResponse()}</b>：{@code ContentCachingResponseWrapper}
 * 把 handler/advice 写出的内容截进内部缓存不落客户端，漏此调用即空响应（绊线断言见
 * {@code IdempotencyCaptureFilterTest}）；它同时自动更新 Content-Length（含重放写出路径）。
 *
 * <p><b>Redis 写失败（出口 SET/DEL）不抛异常</b>：此时控制器已执行、响应已产生，
 * 再抛 50001 会覆盖已成功响应。SET/DEL 失败记 ERROR，依赖占位键 24h TTL 自愈
 * （登记已知代价，随 U8 gap-register 收口）。
 */
public class IdempotencyCaptureFilter extends OncePerRequestFilter {

    /** 日志（独立命名，防 com.s2s: WARN 压制幂等缓存失败告警）。 */
    private static final Logger log = LoggerFactory.getLogger(IdempotencyCaptureFilter.class);

    /** Redis 字符串模板（出口 SET 覆盖 / DEL 占位，构造注入）。 */
    private final StringRedisTemplate redisTemplate;

    /** 幂等键 TTL（24h，与拦截器同源，从 NfrApi 换算）。 */
    private final Duration keyTtl;

    /**
     * 构造捕获 Filter，注入 Redis 模板。
     *
     * @param redisTemplate Redis 字符串模板（成功缓存 SET / 失败 DEL）
     */
    public IdempotencyCaptureFilter(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
        this.keyTtl = Duration.ofHours(NfrApi.IDEMPOTENCY_WINDOW_HOURS);
    }

    /**
     * Filter 主体：包装 response → 驱动链 → 出口按属性分流（重放写出 / 执行者 SET 或 DEL
     * / 无幂等仅复制）→ 末尾必调 {@code copyBodyToResponse()}。
     *
     * @param request  当前 HTTP 请求（属性读取源）
     * @param response 当前 HTTP 响应（包装目标）
     * @param chain    过滤器链（后续横切件与 controller 执行载体）
     * @return void
     * @throws ServletException 链内抛出的 servlet 异常（本 Filter 不吞）
     * @throws IOException      链内或写出时抛出的 IO 异常
     */
    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
            FilterChain chain) throws ServletException, IOException {
        ContentCachingResponseWrapper wrapped = new ContentCachingResponseWrapper(response);
        chain.doFilter(request, wrapped);

        String replayBody = (String) request.getAttribute(IdempotencyInterceptor.ATTR_REPLAY_BODY);
        String redisKey = (String) request.getAttribute(IdempotencyInterceptor.ATTR_REDIS_KEY);

        if (replayBody != null) {
            // 重放者：原样写出首次完成响应（含首次 request_id），不进 controller
            writeReplay(wrapped, replayBody);
        } else if (redisKey != null) {
            // 执行者：按响应状态 SET 缓存或 DEL 占位
            settleExecutorCache(wrapped, redisKey);
        }
        // 无幂等处理：仅复制；以上两分支内部也会 copy，此处统一兜底（幂等返回 false 时
        // controller 未执行，wrapped 无缓存，copy 无害）
        wrapped.copyBodyToResponse();
    }

    /**
     * 重放写出：把缓存的首次完成 JSON 写到响应缓存（Content-Type 纠正为 JSON），
     * 由末尾 {@code copyBodyToResponse()} 统一落客户端。
     *
     * @param wrapped   已包装的响应（写入缓存目标）
     * @param replayBody 首次完成响应的 JSON 文本（含首次 request_id）
     * @throws IOException 写出字节时抛出的 IO 异常
     */
    private void writeReplay(ContentCachingResponseWrapper wrapped, String replayBody)
            throws IOException {
        wrapped.setContentType(MediaType.APPLICATION_JSON_VALUE);
        wrapped.getOutputStream().write(replayBody.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * 执行者出口结算：读响应状态——2xx 则把响应体（完整信封 JSON）SET 覆盖占位键
     * （TTL 24h），非 2xx 则 DEL 占位键（同 Key 重放重新执行）。
     * Redis 写失败记 ERROR 不抛异常（响应已产生，依赖 TTL 自愈）。
     *
     * @param wrapped  已包装的响应（状态与缓存字节读取源）
     * @param redisKey 幂等 Redis 键
     */
    private void settleExecutorCache(ContentCachingResponseWrapper wrapped, String redisKey) {
        int status = wrapped.getStatus();
        if (status >= 200 && status < 300) {
            String bodyJson = new String(wrapped.getContentAsByteArray(), StandardCharsets.UTF_8);
            try {
                redisTemplate.opsForValue().set(
                        redisKey, bodyJson, keyTtl.toSeconds(), TimeUnit.SECONDS);
            } catch (Exception exception) {
                log.error("幂等成功缓存 SET 覆盖失败（依赖 {}h TTL 自愈，登记已知代价）: key={}",
                        NfrApi.IDEMPOTENCY_WINDOW_HOURS, redisKey, exception);
            }
        } else {
            try {
                redisTemplate.delete(redisKey);
            } catch (Exception exception) {
                log.error("幂等占位 DEL 失败（依赖 {}h TTL 自愈，登记已知代价）: key={}",
                        NfrApi.IDEMPOTENCY_WINDOW_HOURS, redisKey, exception);
            }
        }
    }
}