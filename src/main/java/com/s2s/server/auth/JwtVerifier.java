package com.s2s.server.auth;

import com.s2s.server.common.config.SecretsProperties;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.ExpiredJwtException;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.JwtParser;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import javax.crypto.SecretKey;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.stereotype.Component;

/**
 * JWT 验签与黑名单查询组件（[122] U3；详设 §3.1 鉴权段；KTD7/KTD10）。
 *
 * <p>职责两件：
 * <ol>
 *   <li><b>验签与声明解析</b>：用 {@code JWT_SECRET}（HS256）校验 Bearer Token 的签名与
 *       有效期，提取 {@code sub}（userId）与 {@code jti}（Token 唯一标识）；</li>
 *   <li><b>黑名单查询</b>：以 {@code jti} 查 Redis 键 {@code jwt:bl:{jti}}，命中即
 *       Token 已被登出/吊销，返回 40101；键不存在即有效。</li>
 * </ol>
 *
 * <p><b>异常分类</b>（KTD7 红线：Redis 读故障统一 50001，绝不降级放行）：
 * <ul>
 *   <li>签名错 / 格式错 / 过期 —— JWT 本身无效，抛 {@link BizException} 40101；</li>
 *   <li>黑名单命中 —— Token 已被吊销，抛 {@link BizException} 40101；</li>
 *   <li>Redis 查询抛异常（连接失败、超时等）—— 服务端故障，抛 50001；
 *       <b>绝不</b>因 Redis 不可用就「放行当未命中」——那会让攻击者拔掉 Redis 就能
 *       让所有被登出 Token 重新生效（KTD7 是安全红线，不可妥协）。</li>
 * </ul>
 *
 * <p>声明集最小化：仅读 {@code sub}（Long 型 userId）与 {@code jti}（String 型 Token 标识）；
 * 不解析 {@code exp}（jjwt 默认校验）、不读自定义字段——新增声明须需求侧定案，
 * 本类不做扩展预留（YAGNI）。
 *
 * <p><b>密钥来源</b>：{@link SecretsProperties#jwtSecret()}，启动期已通过
 * 「已解析 + ≥32 原始字节」双重守卫（KTD10），本类构造时直接转 {@link SecretKey}，
 * 运行期不重复转换。
 */
@Component
public class JwtVerifier {

    /** 黑名单 Redis 键前缀（{@code jwt:bl:{jti}}）。值无意义，存在即命中。 */
    static final String BLACKLIST_KEY_PREFIX = "jwt:bl:";

    /** JWT 声明名：用户 ID（subject）。 */
    static final String CLAIM_SUB = "sub";

    /** JWT 声明名：Token 唯一标识（JWT ID）。 */
    static final String CLAIM_JTI = "jti";

    /** 验签密钥（HS256，构造时从 SecretsProperties 一次性转换）。 */
    private final SecretKey signingKey;

    /** Redis 字符串操作模板（注入构造器，便于测试替换）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 已构建的 JWT 解析器（[122] review #14 修复：构造期缓存复用）。
     * jjwt 的 {@link JwtParser} 是不可变且线程安全的，本应在构造时构建一次复用；
     * 原实现在每次验签时 {@code Jwts.parser().verifyWith(...).build()} 重建，
     * 属鉴权每请求热路径的无谓分配。
     */
    private final JwtParser parser;

    /**
     * 构造 JWT 验签器：从 {@link SecretsProperties} 取 JWT 密钥并转换为
     * {@link SecretKey}（HMAC-SHA-256），构建并缓存 {@link JwtParser}；注入 Redis 模板供黑名单查询。
     *
     * <p><b>{@code @Autowired} 不可省</b>：本类有两个构造器（本生产构造 + 供
     * {@link #forTest} 使用的私钥构造），Spring 在「多构造器且无 {@code @Autowired}」时
     * 退回无参构造装配，而本类没有无参构造，启动即报
     * {@code No default constructor found}（[122] 实测缺陷，补联调环境时首次全量上下文启动暴露；
     * 单测为切片/MockMvc 装配，未走到真实上下文装配故当时未拦下）。显式标注后
     * Spring 只以本构造器装配，测试路径仍走 {@link #forTest}。
     *
     * @param secretsProperties 全量凭证配置（jwtSecret 字段已在启动期验证非空且 ≥32 字节）
     * @param redisTemplate     Redis 字符串操作模板（黑名单读路径）
     */
    @Autowired
    public JwtVerifier(SecretsProperties secretsProperties, StringRedisTemplate redisTemplate) {
        this.signingKey = Keys.hmacShaKeyFor(secretsProperties.jwtSecret().getBytes(StandardCharsets.UTF_8));
        this.redisTemplate = redisTemplate;
        this.parser = Jwts.parser().verifyWith(this.signingKey).build();
    }

    /**
     * 验签并提取 userId：解析 Bearer Token（不含 "Bearer " 前缀），
     * 校验签名与有效期，查询黑名单，全部通过后返回 userId。
     *
     * <p>失败一律抛 {@link BizException}（40101 或 50001），调用方（AuthInterceptor）
     * 无需再包装——异常直接上抛由 GlobalExceptionHandler 统一映射。
     *
     * @param token 原始 Token 字符串（不含 "Bearer " 前缀，调用方负责剥离）
     * @return {@link Long} userId（声明 sub 的 Long 形态）；永不返回 null
     * @throws BizException 签名无效 / 格式错 / 过期 / 黑名单命中 → 40101；
     *                      Redis 查询异常 → 50001
     */
    public Long verifyAndGetUserId(String token) {
        Claims claims = parseClaims(token);
        String jti = claims.get(CLAIM_JTI, String.class);
        if (jti == null || jti.isBlank()) {
            // jti 缺失：格式不合法（签发方应保证 jti 存在），按无效 Token 处理
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        checkBlacklist(jti);
        return parseUserId(claims);
    }

    /**
     * 验签并提取 userId（<b>允许 Token 已过期</b>，供续期接口使用）。
     *
     * <p>与 {@link #verifyAndGetUserId(String)} 的区别：过期（签名仍合法）不视为失败，
     * 仍提取 {@code sub} 并查黑名单——续期语义是「旧 Token 即使过期，只要未被登出，
     * 就可换新」（plan R3）。签名非法 / 格式错 / 黑名单命中仍 40101。</p>
     *
     * @param token 原始 Token 字符串（不含 "Bearer " 前缀）
     * @return {@link Long} userId；永不返回 null
     * @throws BizException 签名非法/格式错/黑名单命中 → 40101；Redis 异常 → 50001
     */
    public Long verifyAndGetUserIdAllowExpired(String token) {
        Claims claims = parseClaimsAllowExpired(token);
        String jti = claims.get(CLAIM_JTI, String.class);
        if (jti == null || jti.isBlank()) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        checkBlacklist(jti);
        return parseUserId(claims);
    }

    /**
     * 验签并提取 Token 信息（<b>允许过期、不查黑名单</b>，供登出写黑名单用）。
     *
     * <p>与 {@link #verifyAndGetUserIdAllowExpired} 的区别：不查黑名单——登出是<b>写</b>
     * 黑名单（plan R4 读写分工），重复登出应幂等成功，而非因 Token 已在黑名单被拒 40101。
     * 返回 {@link TokenInfo}（userId + jti + 过期时刻）供写黑名单（jti 键 + 到期剩余 TTL）
     * 与清 push_token（userId 定位）使用。</p>
     *
     * @param token 原始 Token 字符串（不含 "Bearer " 前缀）
     * @return {@link TokenInfo} userId + jti + 过期时刻
     * @throws BizException 签名非法/格式错 → 40101
     */
    public TokenInfo verifyAndGetTokenInfoAllowExpired(String token) {
        Claims claims = parseClaimsAllowExpired(token);
        String jti = claims.get(CLAIM_JTI, String.class);
        if (jti == null || jti.isBlank()) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        Long userId = parseUserId(claims);
        Instant expiresAt = claims.getExpiration().toInstant();
        return new TokenInfo(userId, jti, expiresAt);
    }

    /**
     * 解析 JWT 声明体：验签 + 有效期校验，失败统一映射为 40101。
     * 本方法私有，不暴露 Claims 给调用方（最小化依赖面）。
     *
     * @param token 原始 Token 字符串
     * @return {@link Claims} 解析后的声明集
     * @throws BizException 任何 JWT 解析失败 → 40101（签名错、格式错、过期等）
     */
    private Claims parseClaims(String token) {
        try {
            return parser.parseSignedClaims(token).getPayload();
        } catch (JwtException | IllegalArgumentException exception) {
            // jjwt 0.12.x 的所有解析异常基类 JwtException；IllegalArgumentException 覆盖
            // 空串 / null / 格式完全乱码等前置校验失败——统一归 40101
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
    }

    /**
     * 解析 JWT 声明体：验签但<b>允许过期</b>（续期专用）。
     * 过期抛 {@link ExpiredJwtException} 时提取其 claims（签名仍合法），
     * 其余解析失败（签名错 / 格式错）仍 40101。
     *
     * @param token 原始 Token 字符串
     * @return {@link Claims} 解析后的声明集
     * @throws BizException 签名错 / 格式错 → 40101
     */
    private Claims parseClaimsAllowExpired(String token) {
        try {
            return parser.parseSignedClaims(token).getPayload();
        } catch (ExpiredJwtException exception) {
            return exception.getClaims();
        } catch (JwtException | IllegalArgumentException exception) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
    }

    /**
     * 黑名单查询：Redis 键 {@code jwt:bl:{jti}} 存在即命中。
     * Redis 异常 → 50001（KTD7 红线：读故障不降级放行）。
     *
     * @param jti Token 唯一标识（非空）
     * @throws BizException 黑名单命中 → 40101；Redis 异常 → 50001
     */
    private void checkBlacklist(String jti) {
        String key = BLACKLIST_KEY_PREFIX + jti;
        ValueOperations<String, String> ops = redisTemplate.opsForValue();
        Boolean exists;
        try {
            exists = ops.get(key) != null;
        } catch (Exception exception) {
            // Redis 连接失败 / 超时 / 命令执行失败 —— 一律 50001，绝不吞
            throw BizException.of(ErrorCode.INTERNAL_ERROR);
        }
        if (Boolean.TRUE.equals(exists)) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
    }

    /**
     * 从 Claims 的 {@code sub} 字段解析 userId（Long 型）。
     * sub 缺失或非数字 → 40101（Token 格式不合法）。
     *
     * @param claims 已验签的声明集
     * @return long userId
     * @throws BizException sub 缺失或非数字 → 40101
     */
    private Long parseUserId(Claims claims) {
        String sub = claims.getSubject();
        if (sub == null || sub.isBlank()) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        try {
            return Long.parseLong(sub);
        } catch (NumberFormatException exception) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
    }

    /**
     * （测试用）构造带自定义密钥与 Redis 模板的验签器——生产代码仅使用 Spring 注入构造器，
     * 本方法为单元测试提供注入能力（TestDouble 替代真实 Redis）。
     *
     * @param secretKey     HMAC-SHA-256 密钥（字节数 ≥32）
     * @param redisTemplate Redis 字符串模板（可用 mock / 桩实现）
     * @return {@link JwtVerifier} 实例
     */
    static JwtVerifier forTest(SecretKey secretKey, StringRedisTemplate redisTemplate) {
        return new JwtVerifier(secretKey, redisTemplate);
    }

    /**
     * 私有构造：直接接收 SecretKey 与 RedisTemplate，供 {@link #forTest(SecretKey, StringRedisTemplate)}
     * 使用——生产路径走 {@link SecretsProperties} 注入构造，测试路径走本构造，
     * 两条路径共用核心逻辑（parseClaims/checkBlacklist/parseUserId）。
     *
     * @param signingKey    已构造的 HMAC-SHA-256 密钥
     * @param redisTemplate Redis 字符串模板
     */
    private JwtVerifier(SecretKey signingKey, StringRedisTemplate redisTemplate) {
        this.signingKey = signingKey;
        this.redisTemplate = redisTemplate;
        this.parser = Jwts.parser().verifyWith(signingKey).build();
    }

    /**
     * 验签产出的 Token 信息（[123] U7；供登出写黑名单与清 push_token 使用）。
     *
     * @param userId    用户 ID（sub 的 Long 形态）
     * @param jti       Token 唯一标识（黑名单键 {@code jwt:bl:{jti}} 的来源）
     * @param expiresAt Token 过期时刻（黑名单键 TTL = 到该时刻的剩余秒数）
     */
    public record TokenInfo(Long userId, String jti, Instant expiresAt) {
    }
}
