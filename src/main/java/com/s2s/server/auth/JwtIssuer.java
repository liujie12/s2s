package com.s2s.server.auth;

import com.s2s.server.common.config.SecretsProperties;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Date;
import java.util.UUID;
import javax.crypto.SecretKey;
import org.springframework.stereotype.Component;

/**
 * JWT 签发组件（[123] U5；详设 §5.1；plan KTD2）。
 *
 * <p>职责：登录/续期成功后签发单 Token（HS256），声明集最小化为 {@code sub}（userId）、
 * {@code jti}（UUID v4，供登出黑名单 {@code jwt:bl:{jti}} 定位）、{@code iat}、
 * {@code exp}（iat + {@link NfrAuth#TOKEN_TTL_DAYS} 天）。与 {@link JwtVerifier}
 * （只验签 + 查黑名单）互补——本类只签发，不验签、不查黑名单。</p>
 *
 * <p>声明集口径（plan KTD2）：{@code sub} 为 userId 的十进制字符串（验签侧
 * {@code JwtVerifier#parseUserId} 按 {@code Long.parseLong(sub)} 反解）；不解析
 * {@code exp}（jjwt 默认校验）；不加自定义字段（YAGNI）。</p>
 *
 * <p>密钥来源：{@link SecretsProperties#jwtSecret()}（启动期已通过「已解析 + ≥32
 * 原始字节」双重守卫，KTD10），构造时一次性转 {@link SecretKey}，运行期不重复转换。</p>
 */
@Component
public class JwtIssuer {

    /** 签发密钥（HS256，构造时从 SecretsProperties 一次性转换）。 */
    private final SecretKey signingKey;

    /**
     * 构造 JWT 签发器：从 {@link SecretsProperties} 取 JWT 密钥并转换为
     * {@link SecretKey}（HMAC-SHA-256）。
     *
     * @param secretsProperties 全量凭证配置（jwtSecret 字段已在启动期验证非空且 ≥32 字节）
     */
    public JwtIssuer(SecretsProperties secretsProperties) {
        this.signingKey = Keys.hmacShaKeyFor(
                secretsProperties.jwtSecret().getBytes(StandardCharsets.UTF_8));
    }

    /**
     * 签发单 Token（HS256）：声明 {@code sub=userId}、{@code jti=UUID v4}、
     * {@code iat=now}、{@code exp=now+30 天}。
     *
     * @param userId 用户 ID（sub 的十进制字符串源）
     * @return {@link String} 紧凑序列化的 JWT（三段 base64url，不含 "Bearer " 前缀）
     */
    public String issue(long userId) {
        Instant now = Instant.now();
        String jti = UUID.randomUUID().toString();
        return Jwts.builder()
                .subject(String.valueOf(userId))
                .id(jti)
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plus(Duration.ofDays(NfrAuth.TOKEN_TTL_DAYS))))
                .signWith(signingKey)
                .compact();
    }
}
