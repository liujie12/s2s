package com.s2s.server.auth;

import com.s2s.server.auth.dto.DeviceUpsertRequest;
import com.s2s.server.auth.dto.DeviceUpsertResult;
import com.s2s.server.auth.dto.LoginRequest;
import com.s2s.server.auth.dto.LoginResult;
import com.s2s.server.auth.dto.RefreshResult;
import com.s2s.server.auth.dto.SendCodeRequest;
import com.s2s.server.auth.dto.SendCodeResult;
import com.s2s.server.auth.dto.WechatLoginRequest;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.common.web.ClientIp;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 认证域控制器（[123] U4 → U5 → U6；详设 §5.1 auth 域接口）。
 *
 * <p>职责：承载 auth 域 HTTP 入口。已落地 {@code POST /auth/sms/send}（U4）、
 * {@code POST /auth/sms/login}（U5）、{@code POST /auth/token/refresh}（U6）；
 * 登出随 U7 追加。因 auth 域接口路径前缀不一（{@code /auth/sms}、{@code /auth/token}），
 * 本类不设类级 {@code @RequestMapping}，逐方法写完整路径。</p>
 *
 * <p>返回约定：controller 直接返回业务 DTO，由 {@code ResponseBodyWrapper} 统一套壳
 * {@code ApiResponse}（编码规范 §4.3）；输入校验经 {@code @Valid} 触发，失败由
 * {@code GlobalExceptionHandler} 映射 40001。</p>
 *
 * <p>IP 获取：{@code forward-headers-strategy: framework}（[122] KTD2）下，
 * {@code request.getRemoteAddr()} 已是真实客户端 IP。设备指纹取 {@code X-Device-Id}
 * 头（KTD3：明确不可信，仅作 device 表指纹）。</p>
 */
@RestController
public class AuthController {

    /** X-Device-Id 请求头名（KTD3：设备指纹，明确不可信）。 */
    private static final String X_DEVICE_ID_HEADER = "X-Device-Id";

    /** Authorization 请求头名。 */
    private static final String AUTHORIZATION_HEADER = "Authorization";

    /** Bearer 前缀（含空格）。 */
    private static final String BEARER_PREFIX = "Bearer ";

    /** 短信验证码服务（发码逻辑承载）。 */
    private final SmsService smsService;

    /** 认证服务（登录/续期逻辑承载）。 */
    private final AuthService authService;

    /**
     * 构造认证控制器，注入短信验证码服务与认证服务。
     *
     * @param smsService  短信验证码服务（发码逻辑承载）
     * @param authService 认证服务（登录/续期逻辑承载）
     */
    public AuthController(SmsService smsService, AuthService authService) {
        this.smsService = smsService;
        this.authService = authService;
    }

    /**
     * 发送短信验证码（{@code POST /auth/sms/send}）。
     *
     * @param request     发送验证码请求（phone + scene，经 @Valid 校验）
     * @param httpRequest 当前 HTTP 请求（取真实客户端 IP 供 IP 维限频）
     * @return {@link SendCodeResult} 验证码有效期（秒）
     */
    @PostMapping("/auth/sms/send")
    public SendCodeResult sendSmsCode(@Valid @RequestBody SendCodeRequest request,
            HttpServletRequest httpRequest) {
        return smsService.sendCode(request, ClientIp.of(httpRequest));
    }

    /**
     * 短信验证码登录（{@code POST /auth/sms/login}，含首次自动注册）。
     *
     * @param request     登录请求（phone + code + agreed + 可选 platform/push_token）
     * @param httpRequest 当前 HTTP 请求（取 X-Device-Id 头作设备指纹）
     * @return {@link LoginResult}（token + expire_at + is_new_user + user）
     */
    @PostMapping("/auth/sms/login")
    public LoginResult smsLogin(@Valid @RequestBody LoginRequest request,
            HttpServletRequest httpRequest) {
        return authService.loginBySms(request, httpRequest.getHeader(X_DEVICE_ID_HEADER));
    }

    /**
     * 微信授权登录（{@code POST /auth/wechat/login}，B2-6a，含首次自动注册）。
     *
     * <p>客户端经微信 SDK 拉起授权后拿到一次性 {@code code}（最长 64 字符），
     * 服务端向微信服务器交换 {@code openid}（身份归一化键）+ {@code access_token}，
     * 再用 openid 查/建 {@code user_identity}（identity_type=wechat），未命中则自动注册。
     * Token 签发与短信登录完全复用 {@link JwtIssuer}。</p>
     *
     * @param request     登录请求（code + agreed + 可选 platform/push_token）
     * @param httpRequest 当前 HTTP 请求（取 X-Device-Id 头作设备指纹）
     * @return {@link LoginResult}（token + expire_at + is_new_user + user）
     * @throws BizException agreed=false → 40002；code 无效/过期 → 40001；
     *                     微信服务器不可用 → 50302；凭据未配置 → 50001
     */
    @PostMapping("/auth/wechat/login")
    public LoginResult wechatLogin(@Valid @RequestBody WechatLoginRequest request,
            HttpServletRequest httpRequest) {
        return authService.loginByWechat(request, httpRequest.getHeader(X_DEVICE_ID_HEADER));
    }

    /**
     * Token 续期（{@code POST /auth/token/refresh}，单飞调用，无请求体）。
     *
     * <p>旧 Token 取自 {@code Authorization} 头；缺头或非 Bearer 格式 → 40001
     * （openapi「请求形态非法」）。验签/重签发交 {@link AuthService#refresh}。</p>
     *
     * @param httpRequest 当前 HTTP 请求（取 Authorization 头）
     * @return {@link RefreshResult} 新 Token + 到期时间
     */
    @PostMapping("/auth/token/refresh")
    public RefreshResult refreshToken(HttpServletRequest httpRequest) {
        String authHeader = httpRequest.getHeader(AUTHORIZATION_HEADER);
        if (authHeader == null || !authHeader.startsWith(BEARER_PREFIX)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        String token = authHeader.substring(BEARER_PREFIX.length());
        if (token.isBlank()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return authService.refresh(token);
    }

    /**
     * 登出（{@code POST /auth/logout}，无请求体）。
     *
     * <p>旧 Token 取自 Authorization 头（缺头/非 Bearer → 40101，未登录态无法登出；
     * openapi logout 无 400 响应段，缺头归 401）。黑名单 + push_token 清理交
     * {@link AuthService#logout}。</p>
     *
     * @param httpRequest 当前 HTTP 请求（取 Authorization + X-Device-Id 头）
     */
    @PostMapping("/auth/logout")
    public void logout(HttpServletRequest httpRequest) {
        String authHeader = httpRequest.getHeader(AUTHORIZATION_HEADER);
        if (authHeader == null || !authHeader.startsWith(BEARER_PREFIX)) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        String token = authHeader.substring(BEARER_PREFIX.length());
        if (token.isBlank()) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        authService.logout(token, httpRequest.getHeader(X_DEVICE_ID_HEADER));
    }

    /**
     * 上报/更新设备推送 token（{@code POST /users/me/devices}，[B2-2]）。
     *
     * <p><b>为什么路径不带 {@code /auth} 前缀仍在本类</b>：openapi 该端点
     * {@code tags: [auth]}、{@code x-domain: auth}，与登录/登出同属 auth 域；
     * 本类本就不设类级 {@code @RequestMapping}（见类注释），逐方法写完整路径。</p>
     *
     * <p>强制登录态（{@code 40101}）：推送 token 是「发给谁」的强归属数据，
     * 用户标识只取登录态，不接受入参指定。设备指纹取 {@code X-Device-Id} 头。</p>
     *
     * @param request     上报请求（platform + token，经 @Valid 校验）
     * @param httpRequest 当前 HTTP 请求（取登录态 + X-Device-Id 头）
     * @return {@link DeviceUpsertResult}
     * @throws BizException {@code 40101} 未登录 / {@code 40001} 通道非法或指纹缺失
     */
    @PostMapping("/users/me/devices")
    public DeviceUpsertResult upsertDevice(@Valid @RequestBody DeviceUpsertRequest request,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return authService.upsertPushToken(
                userId, httpRequest.getHeader(X_DEVICE_ID_HEADER),
                request.platform(), request.token());
    }
}
