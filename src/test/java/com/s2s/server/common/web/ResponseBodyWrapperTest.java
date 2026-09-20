package com.s2s.server.common.web;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.core.MethodParameter;
import org.springframework.http.MediaType;
import org.springframework.http.converter.StringHttpMessageConverter;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.http.server.ServletServerHttpRequest;
import org.springframework.http.server.ServletServerHttpResponse;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/**
 * {@link ResponseBodyWrapper} 套壳行为测试。
 *
 * <p>覆盖 U-3 任务四场景：record 返回值套壳（code=0、request_id 非空且逐字沿用请求属性）、
 * String 返回值套壳后仍为合法 JSON、已是 {@link ApiResponse} 不二次套壳、{@code /actuator/**} 不套壳；
 * 另补泳道 C 测试伞场景五（P2 登记 #7）：{@code supports()} 普通 DTO 端点正向配对——
 * 原仅负向断言，取反逻辑被改错（如误写恒 {@code false}）测试仍绿，配对后闸门两方向破改均亮红灯。
 * 选纯单测路径（U-3 任务书授权「@WebMvcTest 或纯单测均可，选最快路径」）。
 *
 * <p>proof-first：本测试先于生产代码编写（U-3），首轮运行应编译失败。
 */
class ResponseBodyWrapperTest {

    /** 测试用业务 DTO：验证 record 返回值被套壳时 data 原样保留。 */
    record SampleDto(String name, int count) {
    }

    private final ObjectMapper objectMapper = new ObjectMapper();
    private ResponseBodyWrapper wrapper;

    /**
     * 每测前置：构造 wrapper，并经 {@link RequestContextFixtures} 安装带预置 request_id 的
     * 请求线程上下文（纯单测经夹具直接设置同一属性键，与 [122] RequestIdFilter 生产链首
     * 生成方同键，KTD12 纯单测策略）。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        wrapper = new ResponseBodyWrapper(objectMapper);
        RequestContextFixtures.install("req-pre-set-1");
    }

    /**
     * 每测后置：经 {@link RequestContextFixtures} 清空线程本地请求上下文，避免测试间串扰。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        RequestContextFixtures.clear();
    }

    /**
     * 场景一：record DTO 返回值被统一套壳——code=0、data 为原对象、request_id 逐字沿用请求属性中的值。
     * 依据：详设 §2.1「controller 直接返回业务 DTO，包装器统一套壳，注入当前请求的 request_id」。
     *
     * @return void；断言失败即套壳结构或 request_id 注入逻辑错误
     * @throws NoSuchMethodException 反射取占位方法句柄失败时抛出（测试固有问题，非被测行为）
     */
    @Test
    void wrapsRecordBodyWithOkCodeAndRequestId() throws NoSuchMethodException {
        SampleDto body = new SampleDto("duck", 3);
        MethodParameter returnType = stubMethodParameter("recordEndpoint");

        Object written = wrapper.beforeBodyWrite(body, returnType, MediaType.APPLICATION_JSON,
                MappingJackson2HttpMessageConverter.class,
                servletRequestOf("GET", "/posts"),
                new ServletServerHttpResponse(new MockHttpServletResponse()));

        assertThat(written).isInstanceOf(ApiResponse.class);
        ApiResponse<?> response = (ApiResponse<?>) written;
        assertThat(response.code()).isEqualTo(0);
        assertThat(response.data()).isSameAs(body);
        assertThat(response.requestId()).isEqualTo("req-pre-set-1");
    }

    /**
     * 场景二：String 返回值套壳后仍输出合法 JSON 字符串（Spring 对 String 走
     * {@link StringHttpMessageConverter}，wrapper 必须手动序列化，详设 §2.1 包装器职责）。
     *
     * @return void；断言失败即 String 分支未序列化为 JSON
     * @throws Exception Jackson 解析失败时抛出（断言的一部分：非法 JSON 即测试失败）
     */
    @Test
    void wrapsStringBodyIntoValidJson() throws Exception {
        MethodParameter returnType = stubMethodParameter("stringEndpoint");

        Object written = wrapper.beforeBodyWrite("plain-text", returnType, MediaType.TEXT_PLAIN,
                StringHttpMessageConverter.class,
                servletRequestOf("GET", "/debug/echo"),
                new ServletServerHttpResponse(new MockHttpServletResponse()));

        assertThat(written).isInstanceOf(String.class);
        JsonNode json = objectMapper.readTree((String) written);
        assertThat(json.get("code").asInt()).isEqualTo(0);
        assertThat(json.get("data").asText()).isEqualTo("plain-text");
        assertThat(json.get("request_id").asText()).isEqualTo("req-pre-set-1");
    }

    /**
     * 场景三：controller 声明返回类型已是 {@link ApiResponse} 时 {@code supports()} 返回 false，
     * 不二次套壳（详设 §2.1：唯一套壳处，重复套壳会破坏信封结构）。
     *
     * @return void；断言失败即二次套壳防线失效
     * @throws NoSuchMethodException 反射取占位方法句柄失败时抛出（测试固有问题，非被测行为）
     */
    @Test
    void doesNotWrapWhenReturnTypeAlreadyApiResponse() throws NoSuchMethodException {
        MethodParameter returnType = stubMethodParameter("apiResponseEndpoint");
        assertThat(wrapper.supports(returnType, MappingJackson2HttpMessageConverter.class)).isFalse();
    }

    /**
     * 场景五（泳道 C 测试伞，P2 登记 #7）：{@code supports()} 对普通 DTO 端点返回 {@code true}
     * ——与场景三负向断言配对。{@code supports()} 是全站套壳总闸门，仅负向断言时取反逻辑被
     * 改错（误写恒 {@code false} 或判错类型）测试仍绿；正向配对后两方向破改均触发红灯。
     *
     * @return void；断言失败即套壳总闸门正向判定失效
     * @throws NoSuchMethodException 反射取占位方法句柄失败时抛出（测试固有问题，非被测行为）
     */
    @Test
    void supportsReturnsTrueForPlainDtoEndpoint() throws NoSuchMethodException {
        MethodParameter returnType = stubMethodParameter("recordEndpoint");
        assertThat(wrapper.supports(returnType, MappingJackson2HttpMessageConverter.class)).isTrue();
    }

    /**
     * 场景四：{@code /actuator/**} 运维端点返回值原样放行不套壳（compose healthcheck 依赖原生格式，
     * 部署架构设计文档；U-3 任务书明列排除路径）。
     *
     * @return void；断言失败即 actuator 排除失效
     * @throws NoSuchMethodException 反射取占位方法句柄失败时抛出（测试固有问题，非被测行为）
     */
    @Test
    void doesNotWrapActuatorPath() throws NoSuchMethodException {
        MethodParameter returnType = stubMethodParameter("recordEndpoint");
        Object body = Map.of("status", "UP");

        Object written = wrapper.beforeBodyWrite(body, returnType, MediaType.APPLICATION_JSON,
                MappingJackson2HttpMessageConverter.class,
                servletRequestOf("GET", "/actuator/health"),
                new ServletServerHttpResponse(new MockHttpServletResponse()));

        assertThat(written).isSameAs(body);
    }

    /**
     * 测试辅助：构造 servlet 栈 {@link ServletServerHttpRequest}（{@code ResponseBodyAdvice}
     * 使用的 {@code org.springframework.http.server.ServerHttpRequest} 的可测实现）。
     *
     * @param method HTTP 方法名（如 "GET"）
     * @param path   请求路径（actuator 排除判定依赖它）
     * @return 包装 {@link MockHttpServletRequest} 的 servlet 栈请求对象
     */
    private ServletServerHttpRequest servletRequestOf(String method, String path) {
        return new ServletServerHttpRequest(new MockHttpServletRequest(method, path));
    }

    /**
     * 测试辅助：构造指向占位方法返回值的 {@link MethodParameter}（parameterIndex = -1 是
     * Spring 公开语义「方法返回值」，{@code getParameterType()} 原生返回声明返回类型）。
     * 被测 {@code supports()} 只消费 {@code getParameterType()}，与改写前的 mock 打桩行为等价。
     *
     * @param methodName 占位方法名（须存在于 {@link StubEndpoints}）
     * @return 指向占位方法返回值的 {@link MethodParameter}
     * @throws NoSuchMethodException 占位方法不存在时抛出
     */
    private MethodParameter stubMethodParameter(String methodName) throws NoSuchMethodException {
        return new MethodParameter(StubEndpoints.class.getDeclaredMethod(methodName), -1);
    }

    /**
     * 测试辅助：占位端点集合，仅以声明返回类型承载 supports() 判定所需信息，方法体从不执行。
     */
    @SuppressWarnings("unused")
    private static final class StubEndpoints {

        /**
         * 占位：声明返回 record DTO 的端点。
         *
         * @return 恒 null（仅供反射取返回类型，从不调用）
         */
        SampleDto recordEndpoint() {
            return null;
        }

        /**
         * 占位：声明返回 String 的端点。
         *
         * @return 恒 null（仅供反射取返回类型，从不调用）
         */
        String stringEndpoint() {
            return null;
        }

        /**
         * 占位：声明返回 {@link ApiResponse} 的端点。
         *
         * @return 恒 null（仅供反射取返回类型，从不调用）
         */
        ApiResponse<SampleDto> apiResponseEndpoint() {
            return null;
        }
    }
}
