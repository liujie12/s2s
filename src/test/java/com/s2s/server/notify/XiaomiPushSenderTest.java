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
import com.s2s.server.common.constants.NfrPush;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

/**
 * {@link XiaomiPushSender} 测试（B2-2 阶段 2）。
 *
 * <p><b>全部走 HTTP 打桩、不出网</b>：覆盖「正常下发 / 模板参数 / 标题截断 / 厂商业务失败 /
 * 非 2xx / 凭据缺失」六类。断言只比对请求头与表单结构，不输出密钥。</p>
 */
class XiaomiPushSenderTest {

    /** 打桩 AppSecret（假值）。 */
    private static final String APP_SECRET = "mi-secret";

    /** 打桩包名。 */
    private static final String PACKAGE_NAME = "com.s2s.zhaoyazhao.dev";

    /** 打桩设备 regid（假值）。 */
    private static final String REG_ID = "reg-1";

    private MockRestServiceServer server;
    private RestClient restClient;

    /**
     * 每例新建打桩服务器与客户端，保证用例间零串扰。
     */
    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        restClient = builder.build();
    }

    /**
     * 正常下发：Authorization 用 {@code key=} 前缀，表单含 regid/包名/标题/描述/跳转载荷。
     */
    @Test
    void 正常下发返回true() {
        server.expect(requestTo(XiaomiPushSender.SEND_URL))
                .andExpect(method(HttpMethod.POST))
                .andExpect(header(HttpHeaders.AUTHORIZATION, "key=" + APP_SECRET))
                .andExpect(content().string(containsString("registration_id=" + REG_ID)))
                .andExpect(content().string(containsString("restricted_package_name=" + PACKAGE_NAME)))
                .andExpect(content().string(containsString("title=hello")))
                .andExpect(content().string(containsString("description=world")))
                .andExpect(content().string(containsString("notify_type=1")))
                .andExpect(content().string(containsString("pass_through=0")))
                .andExpect(content().string(containsString("extra.notify_effect=1")))
                .andExpect(content().string(containsString("payload=%7B%22type%22%3A%22interaction%22")))
                .andRespond(withSuccess("{\"result\":\"ok\",\"code\":0,\"description\":\"成功\"}",
                        MediaType.APPLICATION_JSON));

        boolean accepted = sender("", "").send(REG_ID,
                new PushMessage(NotifyType.INTERACTION, "hello", "world", 7L));

        assertThat(accepted).isTrue();
        server.verify();
    }

    /**
     * 配置了 channel/模板时，表单自动附带三件套。
     */
    @Test
    void 配置模板后附带模板参数() {
        server.expect(requestTo(XiaomiPushSender.SEND_URL))
                .andExpect(content().string(containsString("extra.channel_id=ch-1")))
                .andExpect(content().string(containsString("extra.template_id=tpl-1")))
                .andExpect(content().string(containsString("extra.template_param=%7B%7D")))
                .andRespond(withSuccess("{\"code\":0}", MediaType.APPLICATION_JSON));

        boolean accepted = sender("ch-1", "tpl-1").send(REG_ID,
                new PushMessage(NotifyType.CERT, "t", "s", null));

        assertThat(accepted).isTrue();
        server.verify();
    }

    /**
     * 标题超过官方上限时按字符截断（中英文均按 1 计）。
     */
    @Test
    void 标题按官方上限截断() {
        String longTitle = "a".repeat(NfrPush.XIAOMI_TITLE_MAX_CHARS + 10);
        String truncated = "a".repeat(NfrPush.XIAOMI_TITLE_MAX_CHARS);
        server.expect(requestTo(XiaomiPushSender.SEND_URL))
                .andExpect(content().string(containsString("title=" + truncated)))
                .andRespond(withSuccess("{\"code\":0}", MediaType.APPLICATION_JSON));

        assertThat(sender("", "").send(REG_ID,
                new PushMessage(NotifyType.SYSTEM, longTitle, "s", null))).isTrue();
        server.verify();
    }

    /**
     * 厂商业务码非 0：返回 false 且不抛异常。
     */
    @Test
    void 业务码失败返回false() {
        server.expect(requestTo(XiaomiPushSender.SEND_URL))
                .andRespond(withSuccess("{\"result\":\"error\",\"code\":10016,\"description\":\"缺失参数\"}",
                        MediaType.APPLICATION_JSON));

        assertThat(sender("", "").send(REG_ID,
                new PushMessage(NotifyType.SYSTEM, "t", "s", null))).isFalse();
        server.verify();
    }

    /**
     * 非 2xx：RestClient 抛异常，本类归一为 false。
     */
    @Test
    void 非2xx返回false() {
        server.expect(requestTo(XiaomiPushSender.SEND_URL))
                .andRespond(withStatus(HttpStatus.INTERNAL_SERVER_ERROR));

        assertThat(sender("", "").send(REG_ID,
                new PushMessage(NotifyType.SYSTEM, "t", "s", null))).isFalse();
        server.verify();
    }

    /**
     * 启用但凭据为空：构造期快速失败。
     */
    @Test
    void 凭据缺失构造失败() {
        assertThatThrownBy(() -> new XiaomiPushSender(restClient, new ObjectMapper(),
                "", PACKAGE_NAME, "", "", ""))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("XIAOMI_PUSH_APP_SECRET");
    }

    /**
     * 构造被测发送器。
     *
     * @param channelId 私信 channel（可空）
     * @param templateId 私信模板（可空）
     * @return {@link XiaomiPushSender} 使用打桩客户端与假凭据
     */
    private XiaomiPushSender sender(String channelId, String templateId) {
        return new XiaomiPushSender(restClient, new ObjectMapper(), APP_SECRET, PACKAGE_NAME,
                channelId, templateId, "");
    }
}
