package com.s2s.server.realtime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.JwtVerifier;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.socket.WebSocketHandler;

/**
 * 握手鉴权测试：无 Token、非法 Token、有效 Token 三条路径。
 *
 * <p>核心断言是「<b>任何一种失败都必须 401 且不升级连接</b>」——握手是长连接唯一的
 * 身份闸门，这里放过一个，后面所有消息投递都失去身份依据。</p>
 */
class RealtimeHandshakeInterceptorTest {

    /** JWT 验签器替身。 */
    private final JwtVerifier jwtVerifier = mock(JwtVerifier.class);

    /** 被测对象。 */
    private final RealtimeHandshakeInterceptor interceptor =
            new RealtimeHandshakeInterceptor(jwtVerifier);

    /**
     * 未带 Authorization 头：拒绝并写 401。
     *
     * @return void；断言失败即匿名可建连
     */
    @Test
    void rejectsMissingHeader() {
        ServerHttpResponse response = mock(ServerHttpResponse.class);

        boolean accepted = interceptor.beforeHandshake(request(new HttpHeaders()), response,
                mock(WebSocketHandler.class), new HashMap<>());

        assertThat(accepted).isFalse();
        verify(response).setStatusCode(HttpStatus.UNAUTHORIZED);
    }

    /**
     * Token 验签失败（签名错/过期/黑名单）：拒绝并写 401，不向上抛业务异常。
     *
     * @return void；断言失败即握手异常会变成 500 而不是 401
     */
    @Test
    void rejectsInvalidToken() {
        HttpHeaders headers = new HttpHeaders();
        headers.add(HttpHeaders.AUTHORIZATION, "Bearer bad-token");
        when(jwtVerifier.verifyAndGetUserId("bad-token"))
                .thenThrow(BizException.of(ErrorCode.UNAUTHORIZED));
        ServerHttpResponse response = mock(ServerHttpResponse.class);

        boolean accepted = interceptor.beforeHandshake(request(headers), response,
                mock(WebSocketHandler.class), new HashMap<>());

        assertThat(accepted).isFalse();
        verify(response).setStatusCode(HttpStatus.UNAUTHORIZED);
    }

    /**
     * 有效 Token：放行并把 user_id 写入会话属性。
     *
     * @return void；断言失败即已鉴权连接拿不到身份，投递无处可去
     */
    @Test
    void acceptsValidTokenAndStoresUserId() {
        HttpHeaders headers = new HttpHeaders();
        headers.add(HttpHeaders.AUTHORIZATION, "Bearer good-token");
        when(jwtVerifier.verifyAndGetUserId("good-token")).thenReturn(7L);
        Map<String, Object> attributes = new HashMap<>();

        boolean accepted = interceptor.beforeHandshake(request(headers),
                mock(ServerHttpResponse.class), mock(WebSocketHandler.class), attributes);

        assertThat(accepted).isTrue();
        assertThat(RealtimeHandshakeInterceptor.userIdOf(attributes)).isEqualTo(7L);
    }

    /**
     * 构造带指定请求头的升级请求替身。
     *
     * @param headers 请求头
     * @return {@link ServerHttpRequest} 替身
     */
    private ServerHttpRequest request(HttpHeaders headers) {
        ServerHttpRequest request = mock(ServerHttpRequest.class);
        when(request.getHeaders()).thenReturn(headers);
        return request;
    }
}
