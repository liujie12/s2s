package com.s2s.server.common.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * {@code request_id} 的<b>唯一链首生成处</b>与 MDC 生命周期唯一管理者（详设 §3.1/§3.2；
 * 编码规范 §1.2 唯一实现处清单；[122] KTD5）。
 *
 * <p>职责四件（每请求一次，链首执行）：
 * <ol>
 *   <li>生成 UUID v4 {@code request_id}，写入请求属性
 *       {@link ResponseBodyWrapper#REQUEST_ID_ATTRIBUTE}（信封回显的读取键，
 *       {@code ResponseBodyWrapper} 与 {@code GlobalExceptionHandler} 只读不写）与
 *       MDC {@code request_id}；</li>
 *   <li>读 {@code X-Interaction-Id} 头：截断 {@link #INTERACTION_ID_MAX_LENGTH} 字符、
 *       剥除 ISO 控制字符（{@code \p{Cntrl}}，防日志注入撕裂 JSON 单行）后入 MDC，
 *       缺失置空串占位——{@code interaction_id} 仅日志串联，<b>严禁</b>用于
 *       鉴权/限流/幂等判定（详设 §3.2）；</li>
 *   <li>finally 写访问日志：独立命名 logger {@code ACCESS}（刻意不落 {@code com.s2s}
 *       层级，防 deploy 外部配置 {@code com.s2s: WARN} 压制；deploy 三份
 *       application-{env}.yml 显式放行该 logger），携带 path/code/rt_ms 三值；</li>
 *   <li>finally {@code MDC.clear()}——finally 是唯一覆盖 preHandle 异常、advice 异常、
 *       响应已提交等全路径的清理点（KTD5），防容器线程复用串号。</li>
 * </ol>
 *
 * <p><b>访问日志三值承载方式裁定</b>：path/code/rt_ms 经 {@code MDC.put} 后随日志事件
 * 输出再统一清理——与 request_id/interaction_id 同走 MDC 出口，由
 * LogstashEncoder（{@code logback-spring.xml}）统一结构化为可观测 §3 的 8 字段
 * JSON 单行；不选 StructuredArguments（键名散落在消息格式里，与 MDC 两套出口易漂移）。
 * MDC 8 字段中的 {@code user_id} 由 [122] U3 {@code AuthInterceptor} 写入
 * （键名常量 {@link #MDC_USER_ID} 在本类承载，防散落重定义），本 Filter 不碰。
 *
 * <p><b>已知边界（已接受）</b>：Filter 仅注册 {@code DispatcherType.REQUEST}
 * （见 {@code WebCrosscutConfig}），ERROR 派发路径（如容器转发 /error）不经过本 Filter，
 * 该路径日志无 MDC 字段——[122] 计划 KTD12 已裁定此边界随 /error 统一信封留 [124]。
 *
 * <p><b>实现选择</b>：继承 {@link OncePerRequestFilter} 而非裸
 * {@code jakarta.servlet.Filter}——其 already-filtered 请求属性防护在意外扩面注册
 * （FORWARD/ERROR 派发类型被误加）时仍保证每请求至多执行一次 MDC 注入与访问日志，
 * 与「唯一链首生成处」语义自洽；注册面收敛（仅 REQUEST 派发）由组装根双保险。
 */
public class RequestIdFilter extends OncePerRequestFilter {

    /** MDC 键：服务端生成的请求标识（可观测 §3 8 字段之一；详设 §3.2 服务端用途=日志+UI 回显）。 */
    public static final String MDC_REQUEST_ID = "request_id";

    /** MDC 键：客户端交互标识（仅日志串联，详设 §3.2；值来自 X-Interaction-Id 头的净化结果）。 */
    public static final String MDC_INTERACTION_ID = "interaction_id";

    /**
     * MDC 键：登录用户标识。键名常量在此承载（MDC 承载面唯一处），<b>写入方</b>是
     * [122] U3 {@code AuthInterceptor}（鉴权上下文建立时），本 Filter 不写不删——
     * finally 的 {@code MDC.clear()} 统一回收。
     */
    public static final String MDC_USER_ID = "user_id";

    /** MDC 键：访问日志三值之请求路径（request.getRequestURI）。 */
    public static final String MDC_PATH = "path";

    /** MDC 键：访问日志三值之响应状态码（response.getStatus()）。 */
    public static final String MDC_CODE = "code";

    /** MDC 键：访问日志三值之服务端耗时毫秒（System.nanoTime 差值）。 */
    public static final String MDC_RT_MS = "rt_ms";

    /**
     * 访问日志独立 logger 名。刻意不落 {@code com.s2s} 层级：deploy 的
     * application-{staging,prod}.yml 把 {@code com.s2s} 压到 WARN，若访问日志在其
     * 层级下会被静默吞掉（INFO 事件不可见），故独立命名并在三份 yml 显式放行（KTD5）。
     */
    public static final String ACCESS_LOGGER_NAME = "ACCESS";

    /**
     * {@code X-Interaction-Id} 入 MDC 前的截断上限（字符）。出处：契约
     * {@code openapi.yaml} 的 {@code X-Interaction-Id} 参数 {@code schema.maxLength: 64}
     * ——契约层超长本应 40001 拒绝，Filter 属非执法层，截断仅防 MDC 内存放大（防御纵深）。
     */
    public static final int INTERACTION_ID_MAX_LENGTH = 64;

    /** 交互标识请求头名（契约三头之一，详设 §3.2）。 */
    private static final String INTERACTION_ID_HEADER = "X-Interaction-Id";

    /** 访问日志 logger（独立命名，理由见 {@link #ACCESS_LOGGER_NAME}）。 */
    private static final Logger ACCESS_LOG = LoggerFactory.getLogger(ACCESS_LOGGER_NAME);

    /**
     * Filter 主体：注入 request_id/interaction_id 双 MDC 键与请求属性，驱动链，
     * finally 写访问日志（path/code/rt_ms 三值同走 MDC 承载面）并清空 MDC。
     *
     * @param request  当前 HTTP 请求（属性与头的读取源）
     * @param response 当前 HTTP 响应（访问日志 code 值的读取源）
     * @param chain    过滤器链（后续横切件与 controller 的执行载体）
     * @return void
     * @throws ServletException 链内抛出的 servlet 异常（本 Filter 不吞不包装，原样上抛）
     * @throws IOException      链内抛出的 IO 异常（同上）
     */
    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
            FilterChain chain) throws ServletException, IOException {
        long startNanos = System.nanoTime();
        String requestId = UUID.randomUUID().toString();
        request.setAttribute(ResponseBodyWrapper.REQUEST_ID_ATTRIBUTE, requestId);
        MDC.put(MDC_REQUEST_ID, requestId);
        MDC.put(MDC_INTERACTION_ID, sanitizeInteractionId(request.getHeader(INTERACTION_ID_HEADER)));
        try {
            chain.doFilter(request, response);
        } finally {
            // 访问日志三值先入 MDC 再输出（承载方式裁定见类注释），输出后统一清理
            MDC.put(MDC_PATH, request.getRequestURI());
            MDC.put(MDC_CODE, String.valueOf(response.getStatus()));
            MDC.put(MDC_RT_MS, String.valueOf(elapsedMillis(startNanos)));
            ACCESS_LOG.info("access");
            MDC.clear();
        }
    }

    /**
     * 净化 {@code X-Interaction-Id} 头：先截断至 {@link #INTERACTION_ID_MAX_LENGTH} 字符，
     * 再剥除全部 ISO 控制字符（{@code \p{Cntrl}}，含 CR/LF/TAB——防日志注入）；
     * 头缺失或剥除后为空一律返回空串（占位保证 8 字段恒在，不抛异常）。
     *
     * @param header 原始请求头值，可为 {@code null}
     * @return {@link String} 净化后的值：无控制字符、长度 ≤64、永不返回 {@code null}
     */
    private String sanitizeInteractionId(String header) {
        if (header == null) {
            return "";
        }
        String truncated = header.length() <= INTERACTION_ID_MAX_LENGTH
                ? header
                : header.substring(0, INTERACTION_ID_MAX_LENGTH);
        return truncated.replaceAll("\\p{Cntrl}", "");
    }

    /**
     * 计算自链首起的耗时毫秒（访问日志 {@code rt_ms} 值）。
     * {@code System.nanoTime} 单调（同 JVM 内差值非负），{@code Math.max(0, ...)}
     * 是防御性钳位——服务端 rt_ms 与客户端 duration_ms 交叉核对要求恒 ≥0
     * （可观测 §3；差 ≤50ms 核对由服务端侧执行，[129] 消费）。
     *
     * @param startNanos 链首记录的 {@code System.nanoTime()} 值
     * @return long 耗时毫秒，恒 ≥0
     */
    private long elapsedMillis(long startNanos) {
        return Math.max(0, (System.nanoTime() - startNanos) / 1_000_000);
    }
}
