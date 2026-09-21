package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.dto.LoginRequest;
import com.s2s.server.auth.dto.LoginResult;
import com.s2s.server.auth.dto.RefreshResult;
import com.s2s.server.auth.entity.DeviceEntity;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.entity.UserIdentityEntity;
import com.s2s.server.auth.mapper.DeviceMapper;
import com.s2s.server.auth.mapper.UserIdentityMapper;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.Pepper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimiter;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link AuthService} 短信登录测试（[123] U5；详设 §5.1；plan U5 验收四条）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>{@code agreed=false} → 40002；</li>
 *   <li>正确验证码 + 老用户 → 返回 JWT + is_new_user=false；</li>
 *   <li>正确验证码 + 新手机号 → 自动注册 + is_new_user=true；</li>
 *   <li>错误验证码 → 40001（单次失败计数）；</li>
 *   <li>错误验证码达阈值 → 40105 + Retry-After 传播。</li>
 * </ol>
 *
 * <p>测试策略：持久层/Redis/限频/加解密/签发全部 Mockito mock，聚焦 {@code loginBySms}
 * 的编排——协议校验、验证码比对、失败计数直调、注册两步、device 写入、签发顺序。
 * ObjectMapper 与 pepper 用真实实例（反序列化 SmsCode、盲索引 HMAC）。</p>
 */
class AuthServiceTest {

    private static final String PHONE = "13800138000";

    /** 合法 UUID v4 设备指纹（清 push_token 定位用）。 */
    private static final String DEVICE_ID = "550e8400-e29b-41d4-a716-446655440000";

    /** mock 的 Redis 模板。 */
    private StringRedisTemplate redisTemplate;

    /** mock 的字符串 value 操作。 */
    @SuppressWarnings("unchecked")
    private ValueOperations<String, String> valueOps;

    /** mock 的限频计数器。 */
    private RateLimiter rateLimiter;

    /** mock 的加解密门面。 */
    private CryptoFacade cryptoFacade;

    /** mock 的用户 Mapper。 */
    private UserMapper userMapper;

    /** mock 的身份 Mapper。 */
    private UserIdentityMapper userIdentityMapper;

    /** mock 的设备 Mapper。 */
    private DeviceMapper deviceMapper;

    /** mock 的 JWT 签发器。 */
    private JwtIssuer jwtIssuer;

    /** mock 的 JWT 验签器（续期验签允许过期）。 */
    private JwtVerifier jwtVerifier;

    /** 真实 ObjectMapper（反序列化 SmsCode）。 */
    private ObjectMapper objectMapper;

    /** 被测认证服务。 */
    private AuthService authService;

    /**
     * 每测前置：构造 mock 依赖与真实 pepper/ObjectMapper，装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        rateLimiter = mock(RateLimiter.class);
        cryptoFacade = mock(CryptoFacade.class);
        userMapper = mock(UserMapper.class);
        userIdentityMapper = mock(UserIdentityMapper.class);
        deviceMapper = mock(DeviceMapper.class);
        jwtIssuer = mock(JwtIssuer.class);
        jwtVerifier = mock(JwtVerifier.class);
        objectMapper = new ObjectMapper().findAndRegisterModules();
        List<Pepper> peppers = List.of(
                Pepper.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
        authService = new AuthService(redisTemplate, rateLimiter, objectMapper, peppers,
                cryptoFacade, userMapper, userIdentityMapper, deviceMapper, jwtIssuer, jwtVerifier);
    }

    /**
     * 场景一：agreed=false → 40002，不做任何后续动作。
     *
     * @return void
     */
    @Test
    void loginRejectsWhenNotAgreed() {
        LoginRequest request = new LoginRequest(PHONE, "888888", false, null, null);

        assertThatThrownBy(() -> authService.loginBySms(request, null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.AGREEMENT_REQUIRED));
    }

    /**
     * 场景二：正确验证码 + 老用户 → 返回 JWT，is_new_user=false。
     *
     * @return void
     */
    @Test
    void loginReturnsTokenForExistingUser() {
        when(valueOps.get("sms:" + PHONE)).thenReturn(validCodeJson());
        UserIdentityEntity identity = new UserIdentityEntity();
        identity.setUserId(1L);
        when(userIdentityMapper.selectOne(any())).thenReturn(identity);
        UserEntity user = existingUser();
        when(userMapper.selectById(1L)).thenReturn(user);
        when(jwtIssuer.issue(1L)).thenReturn("jwt-token");

        LoginResult result = authService.loginBySms(
                new LoginRequest(PHONE, "888888", true, null, null), null);

        assertThat(result.token()).isEqualTo("jwt-token");
        assertThat(result.isNewUser()).isFalse();
        assertThat(result.user().id()).isEqualTo(1L);
        assertThat(result.user().phoneMask()).isEqualTo("138****8000");
        verify(redisTemplate).delete("rl:login:fail:" + PHONE);
    }

    /**
     * 场景三：正确验证码 + 新手机号 → 自动注册，is_new_user=true。
     *
     * @return void
     */
    @Test
    void loginRegistersNewUser() {
        when(valueOps.get("sms:" + PHONE)).thenReturn(validCodeJson());
        when(userIdentityMapper.selectOne(any())).thenReturn(null);
        when(userMapper.insert(any(UserEntity.class))).thenAnswer(invocation -> {
            UserEntity user = invocation.getArgument(0);
            user.setId(1L);
            return 1;
        });
        when(cryptoFacade.encrypt(anyString(), anyString()))
                .thenReturn(new CryptoFacade.EncryptResult(1, new byte[] {1, 2, 3}));
        when(jwtIssuer.issue(1L)).thenReturn("jwt-token");

        LoginResult result = authService.loginBySms(
                new LoginRequest(PHONE, "888888", true, null, null), null);

        assertThat(result.isNewUser()).isTrue();
        assertThat(result.user().id()).isEqualTo(1L);
        verify(userMapper).insert(any(UserEntity.class));
        verify(userIdentityMapper).insert(any(UserIdentityEntity.class));
    }

    /**
     * 场景四：错误验证码 → 记失败计数并回 40001。
     *
     * @return void
     */
    @Test
    void loginRejectsWrongCode() {
        when(valueOps.get("sms:" + PHONE)).thenReturn(validCodeJson());

        assertThatThrownBy(() -> authService.loginBySms(
                new LoginRequest(PHONE, "000000", true, null, null), null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.PARAM_INVALID));
        verify(rateLimiter).incrementAndCheck(anyList());
    }

    /**
     * 场景五：错误验证码达锁定阈值 → 传播 40105 + Retry-After。
     *
     * @return void
     */
    @Test
    void loginPropagatesLockout() {
        when(valueOps.get("sms:" + PHONE)).thenReturn(validCodeJson());
        doThrow(BizException.ofRetryAfter(ErrorCode.LOGIN_LOCKED, 900))
                .when(rateLimiter).incrementAndCheck(anyList());

        assertThatThrownBy(() -> authService.loginBySms(
                new LoginRequest(PHONE, "000000", true, null, null), null))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.LOGIN_LOCKED);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(900L);
                });
    }

    /**
     * 场景六：有效/过期 Token → 续期返回新 JWT。
     * 过期验签的真实逻辑归 {@link JwtVerifier}（本测试 mock 其返回 userId），
     * 本用例覆盖 AuthService 的续期编排——验签 → 查 user → 重签发。
     *
     * @return void
     */
    @Test
    void refreshReturnsNewTokenForValidOrExpiredToken() {
        when(jwtVerifier.verifyAndGetUserIdAllowExpired("old-token")).thenReturn(1L);
        when(userMapper.selectById(1L)).thenReturn(existingUser());
        when(jwtIssuer.issue(1L)).thenReturn("new-token");

        RefreshResult result = authService.refresh("old-token");

        assertThat(result.token()).isEqualTo("new-token");
        assertThat(result.expireAt()).isNotNull();
        verify(jwtVerifier).verifyAndGetUserIdAllowExpired("old-token");
    }

    /**
     * 场景七：验签失败（签名非法/黑名单命中）→ 40101 传播。
     *
     * @return void
     */
    @Test
    void refreshRejectsInvalidOrBlacklistedToken() {
        doThrow(BizException.of(ErrorCode.UNAUTHORIZED))
                .when(jwtVerifier).verifyAndGetUserIdAllowExpired("bad-token");

        assertThatThrownBy(() -> authService.refresh("bad-token"))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景八：验签通过但用户已注销/删除 → 40101。
     *
     * @return void
     */
    @Test
    void refreshRejectsMissingUser() {
        when(jwtVerifier.verifyAndGetUserIdAllowExpired("old-token")).thenReturn(99L);
        when(userMapper.selectById(99L)).thenReturn(null);

        assertThatThrownBy(() -> authService.refresh("old-token"))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景九：登出 → 写黑名单 jwt:bl:{jti} 至原过期时刻 + 清 device.push_token。
     *
     * @return void
     */
    @Test
    void logoutWritesBlacklistAndClearsPushToken() {
        Instant expiresAt = Instant.now().plus(Duration.ofDays(30));
        when(jwtVerifier.verifyAndGetTokenInfoAllowExpired("token"))
                .thenReturn(new JwtVerifier.TokenInfo(1L, "jti-1", expiresAt));
        DeviceEntity device = new DeviceEntity();
        device.setId(1L);
        device.setUserId(1L);
        device.setFingerprint(DEVICE_ID);
        device.setPushToken("push-token");
        when(deviceMapper.selectOne(any())).thenReturn(device);

        authService.logout("token", DEVICE_ID);

        verify(valueOps).set(eq("jwt:bl:jti-1"), eq("1"), any(Duration.class));
        verify(deviceMapper).updateById(device);
        assertThat(device.getPushToken()).isNull();
    }

    /**
     * 场景十：登出时 Token 已过期 → 跳过写黑名单（TTL ≤ 0），仅清 push_token。
     *
     * @return void
     */
    @Test
    void logoutSkipsBlacklistWhenTokenExpired() {
        Instant expiredAt = Instant.now().minusSeconds(60);
        when(jwtVerifier.verifyAndGetTokenInfoAllowExpired("token"))
                .thenReturn(new JwtVerifier.TokenInfo(1L, "jti-1", expiredAt));

        authService.logout("token", null);

        verify(valueOps, never()).set(anyString(), anyString(), any(Duration.class));
    }

    /**
     * 生成一条未过期验证码的 JSON（code=888888，expire_at 未来）。
     *
     * @return {@link String} 验证码 JSON 文本
     */
    private String validCodeJson() {
        SmsCode smsCode = new SmsCode("888888", Instant.now().plusSeconds(300));
        try {
            return objectMapper.writeValueAsString(smsCode);
        } catch (com.fasterxml.jackson.core.JsonProcessingException exception) {
            throw new IllegalStateException("测试验证码序列化失败", exception);
        }
    }

    /**
     * 构造一个老用户实体（脱敏手机号 + 默认实名/半径档）。
     *
     * @return {@link UserEntity} 已注册用户
     */
    private UserEntity existingUser() {
        UserEntity user = new UserEntity();
        user.setId(1L);
        user.setPhoneMask("138****8000");
        user.setRealnameStatus("none");
        user.setDefaultRadius("3");
        return user;
    }
}
