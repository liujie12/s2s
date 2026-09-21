package com.s2s.server.auth;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.dto.LoginRequest;
import com.s2s.server.auth.dto.LoginResult;
import com.s2s.server.auth.dto.MyProfile;
import com.s2s.server.auth.dto.RefreshResult;
import com.s2s.server.auth.entity.DeviceEntity;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.entity.UserIdentityEntity;
import com.s2s.server.auth.mapper.DeviceMapper;
import com.s2s.server.auth.mapper.UserIdentityMapper;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.common.crypto.BlindIndex;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.Pepper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimiter;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.web.UuidV4;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 认证服务（[123] U3 骨架 → U5 实现 {@code loginBySms}）。
 *
 * <p>职责：短信验证码登录（{@code POST /auth/sms/login}，含首次自动注册），
 * 是 auth 域的核心接口（详设 §5.1）。本单元（U5）只落地 {@code loginBySms}；
 * 续期/登出/查改资料随 U6/U7/U8 追加。</p>
 *
 * <p>登录主路径（详设 §5.1）：
 * <ol>
 *   <li>{@code agreed=false} → 40002（先查协议，避免对未同意用户做任何后续动作）；</li>
 *   <li>验证码校验：读 {@code sms:{phone}} 比对，错误/过期/缺失 → 失败计数
 *       （{@code rl:login:fail:{phone}}，第 5 次触发 40105 + Retry-After），
 *       否则单次错误回 40001（[123] U5 定案口径）；</li>
 *   <li>验证码正确 → 清失败计数 + 删验证码；</li>
 *   <li>手机号盲索引查 {@code user_identity}，未命中则自动注册
 *       （建 {@code user} + {@code user_identity}，同事务）；</li>
 *   <li>写 {@code device}（X-Device-Id 指纹，缺失写匿名行，KTD3）；</li>
 *   <li>签发 JWT（30 天），返回 {@link LoginResult}。</li>
 * </ol>
 *
 * <p>失败计数用详设 §3.4 行 3 的独立限频键（{@code RateLimitTrack.LOGIN_FAIL}），
 * 与验证码值解耦（plan KTD1 初稿的 {@code fail_count} 字段已按此口径回退）——
 * 失败计数不随验证码 TTL（5 分钟）过期丢失，锁定时长独立为 15 分钟。</p>
 *
 * <p>出处：详设 §5.1（auth 域）、PRD §12.2/§3.7、plan R2/KTD1–KTD3。</p>
 */
@Service
public class AuthService {

    /** 身份类型：手机号（Batch1 唯一身份来源）。 */
    private static final String IDENTITY_TYPE_PHONE = "phone";

    /** 实名状态默认值：未实名（Batch1 无实名流程，恒 {@code none}）。 */
    private static final String REALNAME_STATUS_NONE = "none";

    /** 默认搜索半径档（详设 §5.1 user 表默认值 {@code 3}）。 */
    private static final String DEFAULT_RADIUS = "3";

    /** Redis 字符串模板（验证码读取、失败计数清除）。 */
    private final StringRedisTemplate redisTemplate;

    /** 限频计数器（登录失败锁定）。 */
    private final RateLimiter rateLimiter;

    /** Jackson 序列化器（验证码值反序列化）。 */
    private final ObjectMapper objectMapper;

    /** HMAC pepper 列表（手机号盲索引）。 */
    private final List<Pepper> peppers;

    /** 全系统唯一加解密入口（手机号密文落库）。 */
    private final CryptoFacade cryptoFacade;

    /** 用户 Mapper。 */
    private final UserMapper userMapper;

    /** 身份归一化 Mapper。 */
    private final UserIdentityMapper userIdentityMapper;

    /** 设备 Mapper。 */
    private final DeviceMapper deviceMapper;

    /** JWT 签发器。 */
    private final JwtIssuer jwtIssuer;

    /** JWT 验签器（续期验签允许过期）。 */
    private final JwtVerifier jwtVerifier;

    /**
     * 构造认证服务，注入 Redis、限频、加解密、持久层与 JWT 签发器。
     *
     * @param redisTemplate      Redis 字符串模板
     * @param rateLimiter        限频计数器
     * @param objectMapper       Jackson 序列化器
     * @param peppers            HMAC pepper 列表（Spring Bean，由 CryptoConfig 提供）
     * @param cryptoFacade       加解密门面
     * @param userMapper         用户 Mapper
     * @param userIdentityMapper 身份归一化 Mapper
     * @param deviceMapper       设备 Mapper
     * @param jwtIssuer          JWT 签发器
     * @param jwtVerifier        JWT 验签器（续期验签允许过期）
     */
    public AuthService(StringRedisTemplate redisTemplate, RateLimiter rateLimiter,
            ObjectMapper objectMapper, List<Pepper> peppers, CryptoFacade cryptoFacade,
            UserMapper userMapper, UserIdentityMapper userIdentityMapper,
            DeviceMapper deviceMapper, JwtIssuer jwtIssuer, JwtVerifier jwtVerifier) {
        this.redisTemplate = redisTemplate;
        this.rateLimiter = rateLimiter;
        this.objectMapper = objectMapper;
        this.peppers = peppers;
        this.cryptoFacade = cryptoFacade;
        this.userMapper = userMapper;
        this.userIdentityMapper = userIdentityMapper;
        this.deviceMapper = deviceMapper;
        this.jwtIssuer = jwtIssuer;
        this.jwtVerifier = jwtVerifier;
    }

    /**
     * 短信验证码登录（含首次自动注册）。
     *
     * <p>执行顺序即详设 §5.1 主路径（见类 Javadoc）。{@code @Transactional} 保证注册
     * 的 {@code user} + {@code user_identity} 两表写入原子（避免孤儿 user）；Redis
     * 操作不参与 DB 事务，不受影响。</p>
     *
     * @param request  登录请求（phone + code + agreed + 可选 platform/push_token）
     * @param deviceId X-Device-Id 头值（可能为 null 或非法，写 device 用）
     * @return {@link LoginResult}（token + expire_at + is_new_user + user）
     * @throws BizException agreed=false → 40002；验证码错误 → 40001（第 5 次 40105）
     */
    @Transactional
    public LoginResult loginBySms(LoginRequest request, String deviceId) {
        if (!Boolean.TRUE.equals(request.agreed())) {
            throw BizException.of(ErrorCode.AGREEMENT_REQUIRED);
        }

        String phone = request.phone();
        SmsCode smsCode = readCode(phone);
        if (smsCode == null || isExpired(smsCode) || !request.code().equals(smsCode.code())) {
            recordLoginFailure(phone);
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        clearLoginFailure(phone);
        deleteCode(phone);

        UserEntity user = resolveUser(phone);
        boolean isNewUser = user == null;
        if (isNewUser) {
            user = register(phone);
        }

        writeDevice(user.getId(), deviceId, request.platform(), request.pushToken());

        String token = jwtIssuer.issue(user.getId());
        Instant expireAt = Instant.now().plus(Duration.ofDays(NfrAuth.TOKEN_TTL_DAYS));
        return new LoginResult(token, expireAt, isNewUser, MyProfile.from(user));
    }

    /**
     * Token 续期：验签旧 Token（允许过期）+ 查用户状态 + 重签发新 Token。
     *
     * <p>续期语义（plan R3）：旧 Token 即使过期，只要签名合法且未被登出（黑名单），
     * 就换发新 30 天 Token。验签由 {@link JwtVerifier#verifyAndGetUserIdAllowExpired}
     * 完成（签名非法 / 格式错 / 黑名单命中 → 40101，Redis 异常 → 50001）。</p>
     *
     * <p>用户状态：查 {@code user} 确认仍存在（已注销 / 删除则登录态失效 → 40101）。
     * 续期不改变用户资料，出参仅 {@code token} + {@code expire_at}（{@link RefreshResult}）。</p>
     *
     * @param token 旧 Token（不含 "Bearer " 前缀，调用方负责剥离）
     * @return {@link RefreshResult} 新 Token + 到期时间
     * @throws BizException 签名非法 / 格式错 / 黑名单命中 / 用户不存在 → 40101
     */
    public RefreshResult refresh(String token) {
        Long userId = jwtVerifier.verifyAndGetUserIdAllowExpired(token);
        UserEntity user = userMapper.selectById(userId);
        if (user == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        String newToken = jwtIssuer.issue(userId);
        Instant expireAt = Instant.now().plus(Duration.ofDays(NfrAuth.TOKEN_TTL_DAYS));
        return new RefreshResult(newToken, expireAt);
    }

    /**
     * 登出：验签（允许过期、不查黑名单）→ 写黑名单至原过期时刻 → 清设备 push_token。
     *
     * <p>黑名单读写分工（plan R4）：[122] 只落地读路径（{@code JwtVerifier} 查黑名单），
     * 本方法落地写路径——把 {@code jti} 写入 {@code jwt:bl:{jti}}，TTL = 到原过期时刻的
     * 剩余秒数（Token 已过期则 TTL ≤ 0，跳过写黑名单，仅清 push_token）。</p>
     *
     * <p>验签不查黑名单：重复登出应幂等成功（Token 已在黑名单也不拒 40101），
     * 由 {@link JwtVerifier#verifyAndGetTokenInfoAllowExpired} 承载该语义。</p>
     *
     * @param token    当前 Token（不含 "Bearer " 前缀）
     * @param deviceId X-Device-Id 头值（可能 null/非法，清 push_token 用）
     */
    public void logout(String token, String deviceId) {
        JwtVerifier.TokenInfo info = jwtVerifier.verifyAndGetTokenInfoAllowExpired(token);
        Duration ttl = Duration.between(Instant.now(), info.expiresAt());
        if (!ttl.isNegative() && !ttl.isZero()) {
            redisTemplate.opsForValue().set(
                    JwtVerifier.BLACKLIST_KEY_PREFIX + info.jti(), "1", ttl);
        }
        clearPushToken(info.userId(), deviceId);
    }

    /**
     * 清设备推送 token：按 userId + fingerprint 定位 device（防跨用户），置空 push_token。
     * 设备指纹缺失/非法则跳过（无法定位设备）。
     *
     * @param userId   用户 ID
     * @param deviceId X-Device-Id 头值（可能 null/非法）
     */
    private void clearPushToken(Long userId, String deviceId) {
        if (deviceId == null || !UuidV4.isValid(deviceId)) {
            return;
        }
        DeviceEntity device = deviceMapper.selectOne(
                new QueryWrapper<DeviceEntity>()
                        .eq("user_id", userId)
                        .eq("fingerprint", deviceId));
        if (device != null && device.getPushToken() != null) {
            device.setPushToken(null);
            deviceMapper.updateById(device);
        }
    }

    /**
     * 读验证码值：从 Redis {@code sms:{phone}} 取 JSON 并反序列化。
     *
     * @param phone 手机号
     * @return {@link SmsCode} 验证码值；键不存在返回 {@code null}
     * @throws IllegalStateException JSON 反序列化失败（服务端缺陷，兜底 50001）
     */
    private SmsCode readCode(String phone) {
        String json = redisTemplate.opsForValue().get(smsKey(phone));
        if (json == null) {
            return null;
        }
        try {
            return objectMapper.readValue(json, SmsCode.class);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("验证码值反序列化失败", exception);
        }
    }

    /**
     * 判验证码是否过期。
     *
     * @param smsCode 验证码值
     * @return boolean；到期时刻早于当前时刻则 {@code true}
     */
    private boolean isExpired(SmsCode smsCode) {
        return smsCode.expireAt().isBefore(Instant.now());
    }

    /**
     * 记一次登录失败（验证码错误/过期/缺失），直调限频器递增
     * {@code rl:login:fail:{phone}}；第 5 次失败时 {@code RateLimiter} 抛
     * {@code 40105}（needRetryAfter），前 4 次不抛、由调用方回 40001。
     *
     * @param phone 手机号（渠道级维度）
     */
    private void recordLoginFailure(String phone) {
        LocalDate today = RateLimitKeys.today();
        List<RateLimiter.RateLimitEntry> entries = new ArrayList<>();
        for (RateLimitTrack.WindowRule rule : RateLimitTrack.LOGIN_FAIL.rules()) {
            entries.add(RateLimiter.entry(RateLimitKeys.loginFail(phone), rule, today));
        }
        rateLimiter.incrementAndCheck(entries);
    }

    /**
     * 登录成功后清空失败计数（删除 {@code rl:login:fail:{phone}}），
     * 避免「昨天错 4 次、今天成功登录」后下次输错一次即被锁。
     *
     * @param phone 手机号
     */
    private void clearLoginFailure(String phone) {
        redisTemplate.delete(RateLimitKeys.loginFail(phone));
    }

    /**
     * 登录成功后删除验证码键（一次性验证码，用后即焚）。
     *
     * @param phone 手机号
     */
    private void deleteCode(String phone) {
        redisTemplate.delete(smsKey(phone));
    }

    /**
     * 手机号盲索引解析用户：HMAC 盲索引查 {@code user_identity}，命中则回表查
     * {@code user}。未命中返回 {@code null}（调用方据此走注册）。
     *
     * @param phone 手机号明文
     * @return {@link UserEntity} 已注册用户；未命中返回 {@code null}
     */
    private UserEntity resolveUser(String phone) {
        byte[] phoneHash = BlindIndex.hmac(phone, peppers);
        UserIdentityEntity identity = userIdentityMapper.selectOne(
                new QueryWrapper<UserIdentityEntity>()
                        .eq("identity_hash", phoneHash)
                        .eq("identity_type", IDENTITY_TYPE_PHONE));
        if (identity == null) {
            return null;
        }
        return userMapper.selectById(identity.getUserId());
    }

    /**
     * 自动注册：建 {@code user}（脱敏手机号 + 默认实名/半径档）与
     * {@code user_identity}（盲索引 + AEAD 密文 + 版本号，AAD = user_id + identity_type）。
     * 两步在同一事务内（由 {@link #loginBySms} 的 {@code @Transactional} 保证）。
     *
     * @param phone 手机号明文
     * @return {@link UserEntity} 新建的用户
     */
    private UserEntity register(String phone) {
        UserEntity user = new UserEntity();
        user.setPhoneMask(maskPhone(phone));
        user.setRealnameStatus(REALNAME_STATUS_NONE);
        user.setDefaultRadius(DEFAULT_RADIUS);
        userMapper.insert(user);

        byte[] phoneHash = BlindIndex.hmac(phone, peppers);
        CryptoFacade.EncryptResult encrypted =
                cryptoFacade.encrypt(phone, String.valueOf(user.getId()) + IDENTITY_TYPE_PHONE);

        UserIdentityEntity identity = new UserIdentityEntity();
        identity.setUserId(user.getId());
        identity.setIdentityType(IDENTITY_TYPE_PHONE);
        identity.setIdentityHash(phoneHash);
        identity.setIdentityValueEnc(encrypted.ciphertext());
        identity.setKeyVersion(encrypted.keyVersion());
        userIdentityMapper.insert(identity);

        return user;
    }

    /**
     * 写设备：X-Device-Id 合法则按指纹查/插（命中更新 push_token/platform/last_active_at），
     * 缺失或非法则写匿名行（fingerprint 为 null，KTD3：不拦截登录）。
     *
     * @param userId    用户 ID
     * @param deviceId  X-Device-Id 头值（可能 null/非法）
     * @param platform  平台（可空）
     * @param pushToken 推送 token（可空）
     */
    private void writeDevice(Long userId, String deviceId, String platform, String pushToken) {
        DeviceEntity device = new DeviceEntity();
        device.setUserId(userId);
        device.setPlatform(platform);
        device.setPushToken(pushToken);
        device.setLastActiveAt(LocalDateTime.now());

        if (deviceId != null && UuidV4.isValid(deviceId)) {
            device.setFingerprint(deviceId);
            DeviceEntity existing = deviceMapper.selectOne(
                    new QueryWrapper<DeviceEntity>().eq("fingerprint", deviceId));
            if (existing == null) {
                deviceMapper.insert(device);
            } else {
                existing.setPlatform(platform);
                existing.setPushToken(pushToken);
                existing.setLastActiveAt(LocalDateTime.now());
                deviceMapper.updateById(existing);
            }
        } else {
            deviceMapper.insert(device);
        }
    }

    /**
     * 手机号脱敏：前 3 位 + {@code ****} + 后 4 位（如 {@code 138****8000}）。
     *
     * @param phone 11 位手机号明文
     * @return {@link String} 脱敏串（仅展示，不参与任何查询）
     */
    private String maskPhone(String phone) {
        return phone.substring(0, 3) + "****" + phone.substring(7);
    }

    /**
     * 拼装验证码存储键 {@code sms:{phone}}。
     *
     * @param phone 手机号
     * @return {@link String} 验证码存储键
     */
    private String smsKey(String phone) {
        return SmsCodePolicy.SMS_KEY_PREFIX + phone;
    }
}
