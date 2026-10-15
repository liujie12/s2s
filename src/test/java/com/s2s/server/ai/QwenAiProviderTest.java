package com.s2s.server.ai;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.test.web.client.ResponseCreator;
import org.springframework.web.client.RestClient;

/**
 * {@link QwenAiProvider} 测试（B2-4 阶段①，PRD §5.10 Step 3）。
 *
 * <p><b>真分支用 HTTP 打桩、不打真网</b>（{@code MockRestServiceServer.bindTo(RestClient.Builder)}）：
 * 覆盖「正常返回 / 代码块包裹 / 非 2xx / 网络超时 / 响应结构非法 / 未配 Key」六类，
 * 并回归 dry-run 分支（不触发任何 HTTP）。</p>
 *
 * <p><b>安全</b>：断言只比对请求头与请求体结构，不输出用户明文。</p>
 */
class QwenAiProviderTest {

    /** 打桩用 base URL（非真实域名，测试不出网）。 */
    private static final String BASE_URL = "https://dashscope.test/compatible-mode/v1";

    /** 打桩期望命中的完整端点。 */
    private static final String ENDPOINT = BASE_URL + "/chat/completions";

    /** 打桩用 API Key（假值）。 */
    private static final String API_KEY = "sk-test";

    private MockRestServiceServer server;
    private RestClient restClient;
    private ObjectMapper objectMapper;

    /**
     * 每例新建打桩服务器与客户端，保证用例间零串扰。
     */
    @BeforeEach
    void setUp() {
        objectMapper = new ObjectMapper();
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        restClient = builder.baseUrl(BASE_URL).build();
    }

    /**
     * 真分支：正常返回四件套 JSON，且请求头/请求体符合官方兼容口径。
     *
     * @throws Exception 构造打桩响应体失败
     */
    @Test
    void 真分支返回模型JSON() throws Exception {
        server.expect(requestTo(ENDPOINT))
                .andExpect(method(HttpMethod.POST))
                .andExpect(header(HttpHeaders.AUTHORIZATION, "Bearer " + API_KEY))
                .andExpect(content().string(containsString("\"model\":\"qwen-plus\"")))
                .andExpect(content().string(containsString("\"role\":\"system\"")))
                .andExpect(content().string(containsString("\"role\":\"user\"")))
                .andExpect(content().string(containsString("家电维修")))
                .andRespond(withSuccess(chatCompletion("{\"title\":\"家电维修\"}"),
                        MediaType.APPLICATION_JSON));

        String out = liveProvider().generate("{\"text\":\"家电维修\"}", "严格Scope提示词");

        assertThat(out).isEqualTo("{\"title\":\"家电维修\"}");
        server.verify();
    }

    /**
     * 模型输出被 Markdown 代码块包裹时，应剥离到纯 JSON 对象。
     *
     * @throws Exception 构造打桩响应体失败
     */
    @Test
    void 代码块包裹被剥离() throws Exception {
        server.expect(requestTo(ENDPOINT))
                .andRespond(withSuccess(
                        chatCompletion("```json\n{\"title\":\"家电维修\"}\n```"),
                        MediaType.APPLICATION_JSON));

        assertThat(liveProvider().generate("{\"text\":\"家电维修\"}", "p"))
                .isEqualTo("{\"title\":\"家电维修\"}");
    }

    /**
     * 非 2xx（鉴权失败/限流等）→ IllegalStateException（调用方映射 50301）。
     */
    @Test
    void 非2xx响应抛异常() {
        server.expect(requestTo(ENDPOINT))
                .andRespond(withStatus(HttpStatus.UNAUTHORIZED));

        assertThatThrownBy(() -> liveProvider().generate("{\"text\":\"x\"}", "p"))
                .isInstanceOf(IllegalStateException.class);
    }

    /**
     * 网络层失败（超时口径）→ IllegalStateException。
     */
    @Test
    void 网络超时抛异常() {
        server.expect(requestTo(ENDPOINT))
                .andRespond((ResponseCreator) request -> {
                    throw new IOException("read timed out");
                });

        assertThatThrownBy(() -> liveProvider().generate("{\"text\":\"x\"}", "p"))
                .isInstanceOf(IllegalStateException.class);
    }

    /**
     * 响应缺少 choices[0].message.content → IllegalStateException。
     */
    @Test
    void 响应缺content抛异常() {
        server.expect(requestTo(ENDPOINT))
                .andRespond(withSuccess("{\"choices\":[]}", MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> liveProvider().generate("{\"text\":\"x\"}", "p"))
                .isInstanceOf(IllegalStateException.class);
    }

    /**
     * content 内不含 JSON 对象 → IllegalStateException。
     *
     * @throws Exception 构造打桩响应体失败
     */
    @Test
    void content非JSON对象抛异常() throws Exception {
        server.expect(requestTo(ENDPOINT))
                .andRespond(withSuccess(chatCompletion("抱歉，我无法完成"),
                        MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> liveProvider().generate("{\"text\":\"x\"}", "p"))
                .isInstanceOf(IllegalStateException.class);
    }

    /**
     * 未配置 API Key（dry-run=false）→ 立即 IllegalStateException，不发请求。
     */
    @Test
    void 未配置Key抛异常且不发请求() {
        QwenAiProvider provider =
                new QwenAiProvider(false, "  ", "qwen-plus", restClient, objectMapper);

        assertThatThrownBy(() -> provider.generate("{\"text\":\"x\"}", "p"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("DASHSCOPE_API_KEY");
        server.verify();
    }

    /**
     * dry-run 回归：走规则抽取、不触发任何 HTTP（桩服务器零期望仍 verify 通过）。
     */
    @Test
    void dryRun分支不触发HTTP() {
        QwenAiProvider provider =
                new QwenAiProvider(true, "", "qwen-plus", restClient, objectMapper);

        String out = provider.generate(
                "{\"text\":\"楼下超市卖苹果 5 元\",\"leaf_category_id\":10101}", "p");

        assertThat(out).contains("\"title\":\"楼下超市卖苹果 5 元\"")
                .contains("\"price\":5.0")
                .contains("\"leaf_category_id\":10101");
        server.verify();
    }

    /**
     * 造真分支 provider（dry-run=false）。
     *
     * @return {@link QwenAiProvider} 真通道实例
     */
    private QwenAiProvider liveProvider() {
        return new QwenAiProvider(false, API_KEY, "qwen-plus", restClient, objectMapper);
    }

    /**
     * 构造 OpenAI 兼容的对话补全响应体。
     *
     * @param content 模型输出文本（写入 choices[0].message.content）
     * @return {@link String} 响应体 JSON
     * @throws Exception 序列化失败
     */
    private String chatCompletion(String content) throws Exception {
        ObjectNode root = objectMapper.createObjectNode();
        ObjectNode message = root.putArray("choices").addObject().putObject("message");
        message.put("role", "assistant");
        message.put("content", content);
        return objectMapper.writeValueAsString(root);
    }
}
