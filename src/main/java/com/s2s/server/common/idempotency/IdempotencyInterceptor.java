package com.s2s.server.common.idempotency;

import com.s2s.server.common.constants.IdempotencyPolicy;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.common.web.UuidV4;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * 全系统<b>唯一幂等判定处</b>（[122] U5；详设 §3.3；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>本类为「纯判定件」——只负责幂等判定与占位/轮询，<b>不碰响应体</b>；响应体捕获
 * （首次成功响应缓存、失败删占位、重放写出）归 {@link IdempotencyCaptureFilter}
 * （Filter 层，架构评审 P0：拦截器 preHandle 内包装 response 无法传播给 handler，
 * 详见该 Filter 类注释）。判定结果经请求属性传递：
 * <ul>
 *   <li><b>执行者</b>：SETNX 成功 → 写 {@link #ATTR_REDIS_KEY}，返回 {@code true}
 *       （继续进 controller），CaptureFilter 出口负责「成功 SET 覆盖 / 失败 DEL」；</li>
 *   <li><b>重放者</b>：轮询读到首次完成 JSON → 写 {@link #ATTR_REPLAY_BODY}，
 *       返回 {@code false}（不进 controller），CaptureFilter 出口把 JSON 原样写出。</li>
 * </ul>
 *
 * <p>判定流程（详设 §3.3）：
 * <ol>
 *   <li>无 {@code @Idempotent} 注解 / 非 HandlerMethod → 放行；</li>
 *   <li>键校验：{@code Idempotency-Key} 缺失或非 UUID v4（大写/v1/无横杠）→ 40001
 *       不放行（详设 §3.3 正则）；</li>
 *   <li>键维度分流（KTD13）：登录态键 {@code idem:{userId}:{key}}（无 AuthContext 40101）；
 *       匿名键 {@code idem:dev:{deviceId}:{key}}（缺/非法设备头降级
 *       {@code idem:anon:{key}}）；</li>
 *   <li>SETNX 占位 {@code PENDING}（TTL 24h）→ 成功即执行者；</li>
 *   <li>失败 → 轮询（200ms/10s，KTD4）：值仍 {@code PENDING} 继续等、
 *       值为完成 JSON 原样返回、键消失（首次失败已删）重新 SETNX、
 *       超时 50001；</li>
 * </ol>
 *
 * <p><b>Redis 异常（KTD7 读路径）</b>：SETNX / 轮询 GET 抛异常一律 50001，
 * 绝不「放行当成功」——幂等是防重复写账务性操作，Redis 故障放行会导致重复写，
 * 与限频「写失败 WARN 放行」（防滥用非账务）形成对立即是两条不同红线的正确体现。
 *
 * <p>链序位置：限流之后（详设 §3.1「限流必先于幂等」——先挡超限再谈幂等）。
 */
@Component
public class IdempotencyInterceptor implements HandlerInterceptor {

    /** 请求属性键：执行者写入的 Redis 幂等键（CaptureFilter 出口按此 SET/DEL）。 */
    public static final String ATTR_REDIS_KEY = "IDEMPOTENCY_REDIS_KEY";

    /** 请求属性键：重放者写入的首次完成响应 JSON（CaptureFilter 出口原样写出）。 */
    public static final String ATTR_REPLAY_BODY = "IDEMPOTENCY_REPLAY_BODY";

    /** Idempotency-Key 请求头名（契约写接口幂等头）。 */
    private static final String IDEMPOTENCY_KEY_HEADER = "Idempotency-Key";

    /** X-Device-Id 请求头名（契约三头之一，匿名幂等键维度来源，KTD13）。 */
    private static final String DEVICE_ID_HEADER = "X-Device-Id";

    /** 幂等键统一前缀（详设 §3.3 键形 {@code idem:...}）。 */
    private static final String KEY_PREFIX = "idem:";

    /** 日志（独立命名，防 com.s2s: WARN 压制幂等轮询告警）。 */
    private static final Logger log = LoggerFactory.getLogger(IdempotencyInterceptor.class);

    /** Redis 字符串模板（SETNX 占位 / 轮询 GET，构造注入）。 */
    private final StringRedisTemplate redisTemplate;

    /** 幂等键 TTL（24h，从 NfrApi 常量换算，禁内联 24*3600）。 */
    private final Duration keyTtl;

    /** 轮询间隔（毫秒）。生产取 {@link IdempotencyPolicy#POLL_INTERVAL_MILLIS}，
     * 测试可注入短值避免真实等待（KTD4）。 */
    private final long pollIntervalMillis;

    /** 轮询总超时（毫秒）。生产取 {@link IdempotencyPolicy#POLL_TIMEOUT_MILLIS}，测试可注入短值。 */
    private final long pollTimeoutMillis;

    /**
     * 构造幂等拦截器（生产构造，Spring 注入用）：轮询参数取 {@link IdempotencyPolicy} 常量。
     *
     * @param redisTemplate Redis 字符串模板（SETNX 与轮询 GET 载体）
     */
    public IdempotencyInterceptor(StringRedisTemplate redisTemplate) {
        this(redisTemplate, IdempotencyPolicy.POLL_INTERVAL_MILLIS,
                IdempotencyPolicy.POLL_TIMEOUT_MILLIS);
    }

    /**
     * 构造幂等拦截器（显式轮询参数）：供测试注入短间隔/短超时（KTD12 纯单测，轮询超时
     * 场景不能真实等待 10s），生产不直接调用。
     *
     * @param redisTemplate      Redis 字符串模板
     * @param pollIntervalMillis 轮询间隔（毫秒）
     * @param pollTimeoutMillis  轮询总超时（毫秒）
     */
    IdempotencyInterceptor(StringRedisTemplate redisTemplate, long pollIntervalMillis,
            long pollTimeoutMillis) {
        this.redisTemplate = redisTemplate;
        this.keyTtl = Duration.ofHours(NfrApi.IDEMPOTENCY_WINDOW_HOURS);
        this.pollIntervalMillis = pollIntervalMillis;
        this.pollTimeoutMillis = pollTimeoutMillis;
    }

    /**
     * preHandle：幂等纯判定（键校验 → 维度分流 → SETNX/轮询），
     * 判定结果写入请求属性供 CaptureFilter 消费。
     *
     * @param request  当前 HTTP 请求（键/设备头读取源、属性写入目标）
     * @param response 当前 HTTP 响应（本类不写响应，重放写出归 CaptureFilter）
     * @param handler  目标处理器（判断是否带 @Idempotent 注解）
     * @return boolean；执行者 {@code true}（继续进 controller），
     *         重放者 {@code false}（不进 controller），无注解 {@code true}
     * @throws Exception 键非法 40001 / 无登录态 40101 / Redis 故障或轮询超时 50001
     */
    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
            Object handler) throws Exception {
        if (!(handler instanceof HandlerMethod handlerMethod)) {
            return true;
        }
        Idempotent annotation = handlerMethod.getMethodAnnotation(Idempotent.class);
        if (annotation == null) {
            return true;
        }

        String idemKey = request.getHeader(IDEMPOTENCY_KEY_HEADER);
        if (!UuidV4.isValid(idemKey)) {
            // 缺失/大写/v1 统一 40001 不放行（详设 §3.3 幂等键正则）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        String redisKey = buildRedisKey(annotation, request);
        // SETNX 占位；返回 true 即执行者，false 即已有键（并发/重放）进入轮询
        if (tryAcquire(redisKey)) {
            request.setAttribute(ATTR_REDIS_KEY, redisKey);
            return true;
        }
        return pollAndReplay(redisKey, request);
    }

    /**
     * 按 {@code @Idempotent.anonymous} 分流拼装 Redis 键（KTD13）。
     * 登录态键 {@code idem:{userId}:{key}}；匿名键优先设备维度、
     * 缺/非法设备头降级 {@code idem:anon:{key}}。
     *
     * @param annotation 幂等注解（读 anonymous 属性）
     * @param request    当前请求（读 AuthContext 与 X-Device-Id 头）
     * @return {@link String} Redis 幂等键
     * @throws BizException 登录态键但无 AuthContext → 40101
     */
    private String buildRedisKey(Idempotent annotation, HttpServletRequest request) {
        if (annotation.anonymous()) {
            String deviceId = request.getHeader(DEVICE_ID_HEADER);
            if (UuidV4.isValid(deviceId)) {
                return KEY_PREFIX + "dev:" + deviceId + ":" + request.getHeader(IDEMPOTENCY_KEY_HEADER);
            }
            return KEY_PREFIX + "anon:" + request.getHeader(IDEMPOTENCY_KEY_HEADER);
        }
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return KEY_PREFIX + userId + ":" + request.getHeader(IDEMPOTENCY_KEY_HEADER);
    }

    /**
     * 尝试 SETNX 占位（原子 SET NX + TTL 24h），返回是否取得执行权。
     *
     * @param redisKey Redis 幂等键
     * @return boolean；{@code true} = SETNX 成功（本请求是执行者），
     *         {@code false} = 键已存在（并发竞争或重放）
     * @throws BizException Redis 操作异常 → 50001（KTD7 读路径故障不降级）
     */
    private boolean tryAcquire(String redisKey) {
        try {
            Boolean acquired = redisTemplate.opsForValue().setIfAbsent(
                    redisKey, IdempotencyPolicy.PENDING_PLACEHOLDER, keyTtl.toSeconds(), TimeUnit.SECONDS);
            return Boolean.TRUE.equals(acquired);
        } catch (Exception exception) {
            log.error("幂等 SETNX 失败（Redis 故障），返 50001（KTD7 读路径红线）: key={}",
                    redisKey, exception);
            throw BizException.of(ErrorCode.INTERNAL_ERROR);
        }
    }

    /**
     * 轮询占位键直至读到完成响应或超时（KTD4：200ms 间隔 / 10s 总超时）。
     * 键消失（首次执行者失败已 DEL）→ 重新 SETNX 尝试成为执行者。
     *
     * @param redisKey Redis 幂等键
     * @param request  当前请求（重放时写入 ATTR_REPLAY_BODY / 转执行者时写 ATTR_REDIS_KEY）
     * @return boolean；转执行者 {@code true}，重放者 {@code false}
     * @throws BizException 轮询超时 → 50001；Redis 读故障 → 50001
     */
    private boolean pollAndReplay(String redisKey, HttpServletRequest request) {
        long deadline = System.currentTimeMillis() + pollTimeoutMillis;
        // [122] review #15 修复：循环条件加中断判定，线程被中断（容器停机/客户端断开）
        // 时提前退出，不跑满剩余窗口占用 Servlet 线程
        while (System.currentTimeMillis() < deadline && !Thread.currentThread().isInterrupted()) {
            String value = getValue(redisKey);
            if (value == null) {
                // 首次执行者已失败删键 → 本请求重新竞逐执行权
                if (tryAcquire(redisKey)) {
                    request.setAttribute(ATTR_REDIS_KEY, redisKey);
                    return true;
                }
                // 又被别的请求抢走，继续等
            } else if (IdempotencyPolicy.PENDING_PLACEHOLDER.equals(value)) {
                // 首次执行进行中 → 等待后重读
            } else {
                // 完成态 JSON → 重放，原样返回（不进 controller）
                request.setAttribute(ATTR_REPLAY_BODY, value);
                return false;
            }
            sleepQuietly();
        }
        log.warn("幂等轮询超时或被中断（{} ms），返 50001: key={}",
                pollTimeoutMillis, redisKey);
        throw BizException.of(ErrorCode.INTERNAL_ERROR);
    }

    /**
     * 读占位键当前值；Redis 故障直接抛 50001（KTD7 读路径红线）。
     *
     * @param redisKey Redis 幂等键
     * @return {@link String} 键值（PENDING / 完成 JSON / null）
     * @throws BizException Redis 读异常 → 50001
     */
    private String getValue(String redisKey) {
        try {
            return redisTemplate.opsForValue().get(redisKey);
        } catch (Exception exception) {
            log.error("幂等轮询 GET 失败（Redis 故障），返 50001（KTD7 读路径红线）: key={}",
                    redisKey, exception);
            throw BizException.of(ErrorCode.INTERNAL_ERROR);
        }
    }

    /**
     * 轮询间隔睡眠（KTD4：生产 200ms，测试可注入更短）。中断时恢复中断标志（不吞中断语义）。
     */
    private void sleepQuietly() {
        try {
            Thread.sleep(pollIntervalMillis);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
        }
    }
}