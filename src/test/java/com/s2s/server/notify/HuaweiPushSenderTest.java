package com.s2s.server.notify;

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
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

/**
 * {@link HuaweiPushSender} 测试（B2-2 阶段 2）。
 *
 * <p><b>全部走 HTTP 打桩、不出网</b>：覆盖「取 Token → 发消息」正常链路、Token 复用、
 * 厂商业务失败、非 2xx、凭据缺失五类。断言只比对请求头/请求体结构，不输出密钥。</p>
 */
class HuaweiPushSenderTest {

    /** 打桩 AppID（假值）。 */
    private static final String APP_ID = "100000001";

    /** 打桩 AppSecret（假值）。 */
    private static final String APP_SECRET = "hw-secret";

    /** 打桩设备 Token（假值）。 */
    private static final String DEVICE_TOKEN = "device-token-1";

    /** 发消息端点（由 AppID 拼出）。 */
    private static final String SEND_URL = String.format(HuaweiPushSender.SEND_URL_TEMPLATE, APP_ID);

    private MockRestServiceServer server;
    private RestClient restClient;

    /**
     * 每例新建打桩服务器与发送器，保证用例间零串扰。
     */
    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        restClient = builder.build();
    }

    /**
     * 正常链路：先取 Token，再带 Bearer 发消息；请求体含标题、正文、token 与跳转载荷。
     */
    @Test
    void 正常下发返回true() {
        server.expect(requestTo(HuaweiPushSender.OAUTH_TOKEN_URL))
                .andExpect(method(HttpMethod.POST))
                .andExpect(content().string(containsString("grant_type=client_credentials")))
                .andExpect(content().string(containsString("client_id=" + APP_ID)))
                .andRespond(withSuccess("{\"access_token\":\"token-1\",\"expires_in\":172800}",
                        MediaType.APPLICATION_JSON));
        server.expect(requestTo(SEND_URL))
                .andExpect(method(HttpMethod.POST))
                .andExpect(header(HttpHeaders.AUTHORIZATION, "Bearer token-1"))
                .andExpect(content().string(containsString("\"title\":\"标题\"")))
                .andExpect(content().string(containsString("\"body\":\"摘要\"")))
                .andExpect(content().string(containsString("\"token\":[\"" + DEVICE_TOKEN + "\"]")))
                .andExpect(content().string(containsString("\\\"type\\\":\\\"interaction\\\"")))
                .andExpect(content().string(containsString("\\\"targetId\\\":9")))
                .andExpect(content().string(containsString("\"click_action\":{\"type\":1}")))
                .andRespond(withSuccess("{\"code\":\"80000000\",\"msg\":\"success\"}",
                        MediaType.APPLICATION_JSON));

        boolean accepted = sender().send(DEVICE_TOKEN,
                new PushMessage(NotifyType.INTERACTION, "标题", "摘要", 9L));

        assertThat(accepted).isTrue();
        server.verify();
    }

    /**
     * Token 缓存：连续两次下发只应请求一次 OAuth。
     */
    @Test
    void Token缓存后不重复获取() {
        server.expect(requestTo(HuaweiPushSender.OAUTH_TOKEN_URL))
                .andRespond(withSuccess("{\"access_token\":\"token-1\",\"expires_in\":172800}",
                        MediaType.APPLICATION_JSON));
        server.expect(requestTo(SEND_URL))
                .andRespond(withSuccess("{\"code\":\"80000000\"}", MediaType.APPLICATION_JSON));
        server.expect(requestTo(SEND_URL))
                .andRespond(withSuccess("{\"code\":\"80000000\"}", MediaType.APPLICATION_JSON));

        HuaweiPushSender sender = sender();
        PushMessage message = new PushMessage(NotifyType.SYSTEM, "t", "s", null);
        assertThat(sender.send(DEVICE_TOKEN, message)).isTrue();
        assertThat(sender.send(DEVICE_TOKEN, message)).isTrue();
        server.verify();
    }

    /**
     * 厂商业务码非成功：返回 false 且不抛异常。
     */
    @Test
    void 业务码失败返回false() {
        server.expect(requestTo(HuaweiPushSender.OAUTH_TOKEN_URL))
                .andRespond(withSuccess("{\"access_token\":\"token-1\",\"expires_in\":172800}",
                        MediaType.APPLICATION_JSON));
        server.expect(requestTo(SEND_URL))
                .andRespond(withSuccess("{\"code\":\"80300007\",\"msg\":\"token invalid\"}",
                        MediaType.APPLICATION_JSON));

        assertThat(sender().send(DEVICE_TOKEN,
                new PushMessage(NotifyType.SYSTEM, "t", "s", null))).isFalse();
        server.verify();
    }

    /**
     * 发消息非 2xx：RestClient 抛异常，本类归一为 false。
     */
    @Test
    void 非2xx返回false() {
        server.expect(requestTo(HuaweiPushSender.OAUTH_TOKEN_URL))
                .andRespond(withSuccess("{\"access_token\":\"token-1\",\"expires_in\":172800}",
                        MediaType.APPLICATION_JSON));
        server.expect(requestTo(SEND_URL))
                .andRespond(withStatus(HttpStatus.INTERNAL_SERVER_ERROR));

        assertThat(sender().send(DEVICE_TOKEN,
                new PushMessage(NotifyType.SYSTEM, "t", "s", null))).isFalse();
        server.verify();
    }

    /**
     * OAuth 失败：不发消息，直接返回 false。
     */
    @Test
    void 取Token失败返回false() {
        server.expect(requestTo(HuaweiPushSender.OAUTH_TOKEN_URL))
                .andRespond(withStatus(HttpStatus.UNAUTHORIZED));

        assertThat(sender().send(DEVICE_TOKEN,
                new PushMessage(NotifyType.SYSTEM, "t", "s", null))).isFalse();
        server.verify();
    }

    /**
     * 启用但凭据为空：构造期快速失败（不给静默降级留口子）。
     */
    @Test
    void 凭据缺失构造失败() {
        assertThatThrownBy(() -> new HuaweiPushSender(restClient, new ObjectMapper(), "", "s"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("HUAWEI_PUSH_APP_ID");
    }

    /**
     * 构造被测发送器。
     *
     * @return {@link HuaweiPushSender} 使用打桩客户端与假凭据
     */
    private HuaweiPushSender sender() {
        return new HuaweiPushSender(restClient, new ObjectMapper(), APP_ID, APP_SECRET);
    }
}
