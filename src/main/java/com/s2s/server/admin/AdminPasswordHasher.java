package com.s2s.server.admin;

import com.s2s.server.common.constants.NfrAdmin;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import org.springframework.stereotype.Component;

/**
 * 后台口令哈希器（[153] B2-5）。
 *
 * <p>职责：口令的**唯一哈希/校验实现处** —— 后台账号存储只落 PBKDF2-HMAC-SHA256
 * 派生值（格式 {@code pbkdf2$迭代$盐b64$哈希b64}），**禁存明文**。</p>
 *
 * <p>为什么 PBKDF2 而非 BCrypt/Argon2：本工程未引入 Spring Security（{@code pom.xml}
 * 无 {@code spring-security-crypto}），而为后台口令引入一套安全框架的代价与该面
 * （内网/白名单登录、账号量极小）不匹配；PBKDF2-HMAC-SHA256 是 JDK
 * {@link SecretKeyFactory} 内置能力，**零新增依赖**且是 NIST 认可的口令派生函数。
 * 迭代次数落 {@link NfrAdmin#PASSWORD_PBKDF2_ITERATIONS}（阈值只引用常量）。</p>
 *
 * <p>校验用 {@link MessageDigest#isEqual} 做**定长时间比较**，避免按字节短路比较
 * 泄漏「前几位是否命中」的时序侧信道。</p>
 */
@Component
public class AdminPasswordHasher {

    /** 哈希算法名（JDK 内置）。 */
    private static final String ALGORITHM = "PBKDF2WithHmacSHA256";

    /** 存储格式前缀（供将来更换算法时按前缀分流校验）。 */
    private static final String FORMAT_PREFIX = "pbkdf2";

    /** 存储格式分隔符。 */
    private static final String SEPARATOR = "$";

    /** 随机源（盐生成）。 */
    private final SecureRandom secureRandom = new SecureRandom();

    /**
     * 生成口令哈希串。
     *
     * @param rawPassword 口令明文（非空）
     * @return {@link String} 存储串 {@code pbkdf2$迭代$盐b64$哈希b64}
     */
    public String hash(String rawPassword) {
        byte[] salt = new byte[NfrAdmin.PASSWORD_SALT_BYTES];
        secureRandom.nextBytes(salt);
        byte[] derived = derive(rawPassword, salt, NfrAdmin.PASSWORD_PBKDF2_ITERATIONS);
        return FORMAT_PREFIX + SEPARATOR + NfrAdmin.PASSWORD_PBKDF2_ITERATIONS + SEPARATOR
                + Base64.getEncoder().encodeToString(salt) + SEPARATOR
                + Base64.getEncoder().encodeToString(derived);
    }

    /**
     * 校验口令是否匹配存储串。
     *
     * @param rawPassword  口令明文
     * @param storedValue  存储串（{@code pbkdf2$迭代$盐b64$哈希b64}）
     * @return boolean；{@code true} 表示匹配。存储串格式非法/为空时返回 {@code false}
     *         （不抛异常：登录失败应为业务结果，不给调用方制造异常分支）
     */
    public boolean matches(String rawPassword, String storedValue) {
        if (rawPassword == null || storedValue == null) {
            return false;
        }
        String[] parts = storedValue.split("\\" + SEPARATOR);
        if (parts.length != 4 || !FORMAT_PREFIX.equals(parts[0])) {
            return false;
        }
        int iterations;
        byte[] salt;
        byte[] expected;
        try {
            iterations = Integer.parseInt(parts[1]);
            salt = Base64.getDecoder().decode(parts[2]);
            expected = Base64.getDecoder().decode(parts[3]);
        } catch (IllegalArgumentException exception) {
            return false;
        }
        byte[] actual = derive(rawPassword, salt, iterations);
        return MessageDigest.isEqual(expected, actual);
    }

    /**
     * PBKDF2 派生。
     *
     * @param rawPassword 口令明文
     * @param salt        盐
     * @param iterations  迭代次数
     * @return byte[] 派生密钥字节
     */
    private byte[] derive(String rawPassword, byte[] salt, int iterations) {
        PBEKeySpec spec = new PBEKeySpec(rawPassword.toCharArray(), salt, iterations,
                NfrAdmin.PASSWORD_HASH_BITS);
        try {
            return SecretKeyFactory.getInstance(ALGORITHM).generateSecret(spec).getEncoded();
        } catch (Exception exception) {
            // 算法为 JDK 内置，正常不触发；触发即环境异常，快速失败优于静默降级
            throw new IllegalStateException("口令哈希失败（PBKDF2 不可用）", exception);
        } finally {
            spec.clearPassword();
        }
    }

    /**
     * （测试辅助）以固定盐生成存储串，使哈希可复现。
     *
     * @param rawPassword 口令明文
     * @param salt        指定盐
     * @return {@link String} 存储串
     */
    String hashWithSalt(String rawPassword, byte[] salt) {
        byte[] derived = derive(rawPassword, salt, NfrAdmin.PASSWORD_PBKDF2_ITERATIONS);
        return FORMAT_PREFIX + SEPARATOR + NfrAdmin.PASSWORD_PBKDF2_ITERATIONS + SEPARATOR
                + Base64.getEncoder().encodeToString(salt) + SEPARATOR
                + Base64.getEncoder().encodeToString(derived);
    }

    /**
     * （测试辅助）取 UTF-8 字节，供构造固定盐。
     *
     * @param text 文本
     * @return byte[] UTF-8 字节
     */
    static byte[] utf8(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }
}
