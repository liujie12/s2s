package com.s2s.server.common.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.config.WebCrosscutConfig;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import static org.mockito.Mockito.mock;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.core.Ordered;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/**
 * {@link RequestIdFilter} 行为测试（[122] U2；详设 §3.1/§3.2；KTD5）。
 *
 * <p>覆盖计划 U2 六场景：带头请求（MDC 双键 + 请求属性）、缺头请求（interaction_id 空串）、
 * 超长头截断与控制字符剥除、chain 抛异常后的 finally MDC 清理、访问日志三值
 * （path/code/rt_ms）经独立 ACCESS logger 结构化输出、注册序最高优先级且仅 REQUEST 派发。
 *
 * <p>MDC 断言时机说明：Filter 的 finally 会 {@code MDC.clear()}，故「链内」MDC 值经
 * {@link MdcCapturingChain} 在 doFilter 内拍快照，「链后」断言清理效果与请求属性。
 *
 * <p>proof-first：本测试先于生产代码编写（U2），首轮运行应编译失败（Filter 未实现）。
 */
class RequestIdFilterTest {

    /** 被测 Filter（无状态，逐测新建避免用例间干扰）。 */
    private RequestIdFilter filter;

    /** 挂在 ACCESS logger 上的事件收集器（访问日志断言承载面）。 */
    private ListAppender<ILoggingEvent> accessAppender;

    /** ACCESS logger 的 logback 实例引用（挂/摘 appender 用）。 */
    private Logger accessLogger;

    /**
     * 每测前置：新建被测 Filter，把 ListAppender 挂上独立命名的 ACCESS logger 并清空 MDC
     * （防上一个用例残留键被误读为本用例产物）。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        filter = new RequestIdFilter();
        accessLogger = (Logger) LoggerFactory.getLogger(RequestIdFilter.ACCESS_LOGGER_NAME);
        accessAppender = new ListAppender<>();
        accessAppender.start();
        accessLogger.addAppender(accessAppender);
        accessLogger.setLevel(Level.INFO);
        MDC.clear();
    }

    /**
     * 每测后置：摘除 appender（防泄漏到后续测试类的 logger 状态）并清空 MDC。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        accessLogger.detachAppender(accessAppender);
        MDC.clear();
    }

    /**
     * 场景一：带合法 {@code X-Interaction-Id} 头的请求——链内 MDC 同时含服务端生成的
     * {@code request_id} 与逐字透传的 {@code interaction_id}；请求属性写入同一
     * {@code request_id}（{@code ResponseBodyWrapper} 信封回显的读取键，详设 §3.2 两 ID 分工）。
     *
     * @return void；断言失败即 MDC 注入或请求属性写入缺失
     * @throws Exception mock 链执行失败时抛出（测试固有问题）
     */
    @Test
    void writesRequestIdAndInteractionIdIntoMdcWhenHeaderPresent() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("X-Interaction-Id", "inter-abc-123");
        MdcCapturingChain chain = new MdcCapturingChain();

        filter.doFilter(request, new MockHttpServletResponse(), chain);

        assertThat(chain.captured.get(RequestIdFilter.MDC_REQUEST_ID)).isNotBlank();
        assertThat(chain.captured.get(RequestIdFilter.MDC_INTERACTION_ID)).isEqualTo("inter-abc-123");
        assertThat(request.getAttribute(ResponseBodyWrapper.REQUEST_ID_ATTRIBUTE))
                .isEqualTo(chain.captured.get(RequestIdFilter.MDC_REQUEST_ID));
    }

    /**
     * 场景二：缺 {@code X-Interaction-Id} 头的请求——MDC 的 {@code interaction_id} 置空串
     * （占位保证 8 字段恒在，可观测 §3），不抛异常。
     *
     * @return void；断言失败即缺头路径未置空串或抛异常
     * @throws Exception mock 链执行失败时抛出（测试固有问题）
     */
    @Test
    void setsEmptyInteractionIdWhenHeaderMissing() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        MdcCapturingChain chain = new MdcCapturingChain();

        filter.doFilter(request, new MockHttpServletResponse(), chain);

        assertThat(chain.captured.get(RequestIdFilter.MDC_INTERACTION_ID)).isEmpty();
    }

    /**
     * 场景三a：超长头（&gt;64 字符）截断至 64——上限出处 openapi.yaml
     * {@code X-Interaction-Id.schema.maxLength: 64}（契约层超长本应 40001 拒绝，
     * Filter 属非执法层，仅防 MDC 内存放大）。
     *
     * @return void；断言失败即截断缺失
     * @throws Exception mock 链执行失败时抛出（测试固有问题）
     */
    @Test
    void truncatesOverlongInteractionIdHeader() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("X-Interaction-Id", "x".repeat(100));
        MdcCapturingChain chain = new MdcCapturingChain();

        filter.doFilter(request, new MockHttpServletResponse(), chain);

        assertThat(chain.captured.get(RequestIdFilter.MDC_INTERACTION_ID)).hasSize(64);
    }

    /**
     * 场景三b：含 CRLF 控制字符的头——ISO 控制字符（{@code \p{Cntrl}}）剥除后入 MDC，
     * 防日志注入（JSON 单行落盘被换行/制表符撕裂）。
     *
     * @return void；断言失败即控制字符剥除缺失
     * @throws Exception mock 链执行失败时抛出（测试固有问题）
     */
    @Test
    void stripsControlCharactersFromInteractionIdHeader() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        request.addHeader("X-Interaction-Id", "evil\r\nFAKE-LOG: 1\tinject");
        MdcCapturingChain chain = new MdcCapturingChain();

        filter.doFilter(request, new MockHttpServletResponse(), chain);

        String sanitized = chain.captured.get(RequestIdFilter.MDC_INTERACTION_ID);
        assertThat(sanitized).isEqualTo("evilFAKE-LOG: 1inject");
        assertThat(sanitized).doesNotContain("\r", "\n", "\t");
    }

    /**
     * 场景四：chain 抛异常——异常向上传播（Filter 不吞），但 finally 已执行
     * {@code MDC.clear()}（线程复用防串号，KTD5：finally 是全路径唯一清理点）。
     *
     * @return void；断言失败即清理缺失（下个请求会读到上个请求的 request_id）
     */
    @Test
    void clearsMdcInFinallyWhenChainThrows() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts");
        FilterChain throwingChain = (req, res) -> {
            throw new IllegalStateException("chain blows up");
        };

        assertThatThrownBy(() -> filter.doFilter(request, new MockHttpServletResponse(), throwingChain))
                .isInstanceOf(IllegalStateException.class);
        assertThat((Map<String, String>) MDC.getCopyOfContextMap()).isNullOrEmpty();
    }

    /**
     * 场景五：访问日志——独立命名 ACCESS logger 收到一条 INFO 事件，其 MDC 携带
     * path/code/rt_ms 三值（承载方式裁定见 {@code RequestIdFilter} 类注释：三值经 MDC
     * 由 LogstashEncoder 统一结构化输出）；rt_ms 为 {@code System.nanoTime} 差值毫秒，
     * 断言 ≥0（mock 链亚毫秒耗时属正常，不得断言 &gt;0）。
     *
     * @return void；断言失败即访问日志缺失或三值未进结构化承载面
     * @throws Exception mock 链执行失败时抛出（测试固有问题）
     */
    @Test
    void emitsAccessLogWithPathCodeRtMs() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/posts/42");
        MockHttpServletResponse response = new MockHttpServletResponse();
        response.setStatus(200);

        filter.doFilter(request, response, (req, res) -> {
            // 空链：仅驱动 Filter 生命周期走到 finally
        });

        assertThat(accessAppender.list).hasSize(1);
        ILoggingEvent event = accessAppender.list.get(0);
        assertThat(event.getLevel()).isEqualTo(Level.INFO);
        Map<String, String> mdc = event.getMDCPropertyMap();
        assertThat(mdc.get(RequestIdFilter.MDC_PATH)).isEqualTo("/posts/42");
        assertThat(mdc.get(RequestIdFilter.MDC_CODE)).isEqualTo("200");
        assertThat(Long.parseLong(mdc.get(RequestIdFilter.MDC_RT_MS))).isGreaterThanOrEqualTo(0);
        // 访问日志发出后 MDC 已清（finally 收尾顺序：先输出再清理）
        assertThat((Map<String, String>) MDC.getCopyOfContextMap()).isNullOrEmpty();
    }

    /**
     * 场景六：注册口径——{@code FilterRegistrationBean} 的 order 为
     * {@link Ordered#HIGHEST_PRECEDENCE}（链首铁位）且仅注册 {@code DispatcherType.REQUEST}
     * （ERROR 派发不重复执行，已知边界见 Filter 类 Javadoc）。
     * dispatcherTypes 经反射读取：Boot 3.5 的 {@code FilterRegistrationBean} 只有
     * setter 无 getter，字段名随 Boot 3.5.16 固定（升级若改名，本断言失败即守门提醒）。
     *
     * @return void；断言失败即注册序被降位或派发类型扩面
     */
    @Test
    void registersFilterAtHighestPrecedenceForRequestDispatchOnly() {
        AuthInterceptor mockAuth = mock(AuthInterceptor.class);
        com.s2s.server.common.ratelimit.RateLimitInterceptor mockRateLimit =
                mock(com.s2s.server.common.ratelimit.RateLimitInterceptor.class);
        FilterRegistrationBean<RequestIdFilter> registration =
                new WebCrosscutConfig(mockAuth, mockRateLimit).requestIdFilterRegistration();

        assertThat(registration.getOrder()).isEqualTo(Ordered.HIGHEST_PRECEDENCE);
        assertThat(readDispatcherTypes(registration)).isEqualTo(java.util.EnumSet.of(DispatcherType.REQUEST));
    }

    /**
     * 测试辅助：反射读取 {@code AbstractFilterRegistrationBean.dispatcherTypes} 私有字段
     * （Boot 未提供 getter，理由见场景六注释）。
     *
     * @param registration 待读取的注册描述
     * @return Object 实际为 {@code EnumSet<DispatcherType>}；字段不可达时返回 null（断言随之失败）
     */
    private Object readDispatcherTypes(FilterRegistrationBean<RequestIdFilter> registration) {
        try {
            var field = org.springframework.boot.web.servlet.AbstractFilterRegistrationBean.class
                    .getDeclaredField("dispatcherTypes");
            field.setAccessible(true);
            return field.get(registration);
        } catch (ReflectiveOperationException exception) {
            return null;
        }
    }

    /**
     * 测试辅助链：在 {@code doFilter} 调用点拍下当前线程 MDC 快照——「链内」视角是
     * MDC 断言的唯一正确时机（Filter 的 finally 在链返回后即 clear）。
     */
    private static final class MdcCapturingChain implements FilterChain {

        /** 链内捕获的 MDC 快照（键值原样）。 */
        private final Map<String, String> captured = new HashMap<>();

        /**
         * 拍快照后即返回（被测行为全在 Filter 侧，链本体无事可做）。
         *
         * @param request  链上的请求对象（本链不消费）
         * @param response 链上的响应对象（本链不消费）
         * @return void
         */
        @Override
        public void doFilter(ServletRequest request, ServletResponse response) {
            Map<String, String> snapshot = MDC.getCopyOfContextMap();
            if (snapshot != null) {
                captured.putAll(snapshot);
            }
        }
    }
}
