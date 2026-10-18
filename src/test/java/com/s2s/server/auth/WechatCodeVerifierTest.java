package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link WechatCodeVerifier} 返回体解析测试（B2-6a）。
 *
 * <p>覆盖：unionid 必填（身份键）、openid 仅诊断、微信业务错误 → 40001。
 * 不发起 HTTP：直接调用包级可见的 {@link WechatCodeVerifier#parseResponse(String)}。</p>
 */
class WechatCodeVerifierTest {

    /** 被测解析器（secrets 传 null：parseResponse 不消费凭证）。 */
    private WechatCodeVerifier verifier;

    /**
     * 每测前置：构造仅用于解析的验证器。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        verifier = new WechatCodeVerifier(null, new ObjectMapper());
    }

    /**
     * 成功：返回 unionid 作为身份键，openid 保留诊断。
     *
     * @return void
     * @throws Exception 解析异常（不应发生）
     */
    @Test
    void parseReturnsUnionidAsIdentityKey() throws Exception {
        String body = """
                {"openid":"openid-1","unionid":"unionid-1","access_token":"at",
                 "expires_in":7200,"refresh_token":"rt","scope":"snsapi_userinfo"}
                """;

        WechatCodeVerifier.WechatTokenResult result = verifier.parseResponse(body);

        assertThat(result.unionid()).isEqualTo("unionid-1");
        assertThat(result.openid()).isEqualTo("openid-1");
        assertThat(result.accessToken()).isEqualTo("at");
        assertThat(result.expiresIn()).isEqualTo(7200);
    }

    /**
     * 缺 unionid：拒绝登录（40001），避免同一用户生成第二条身份。
     *
     * @return void
     * @throws Exception 解析异常（不应发生）
     */
    @Test
    void parseRejectsMissingUnionid() throws Exception {
        String body = """
                {"openid":"openid-1","access_token":"at","expires_in":7200}
                """;

        assertThatThrownBy(() -> verifier.parseResponse(body))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));
    }

    /**
     * 微信业务错误（errcode）：原样映射 40001。
     *
     * @return void
     * @throws Exception 解析异常（不应发生）
     */
    @Test
    void parseMapsWechatBusinessErrorToParamInvalid() throws Exception {
        String body = """
                {"errcode":40029,"errmsg":"invalid code"}
                """;

        assertThatThrownBy(() -> verifier.parseResponse(body))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));
    }
}
