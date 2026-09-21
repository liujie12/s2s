package com.s2s.server.common.crypto;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

/**
 * AEAD 主密钥条目（详设 §4.1 三列范式；安全 §4：AES-GCM-256 密钥，按版本轮换）。
 *
 * <p>JSON 形态（与 {@code SecretsProperties.aeadMasterKeysJson} 绑定源一致）：
 * {@code [{"version":1,"key":"<32字节hex或base64>"}]}。</p>
 *
 * <p>{@link #version()} 与数据库 {@code key_version TINYINT} 列一一对应——
 * 详设 §4.1 把版本号定义为<b>独立列</b>而非编码进密文，故解密时由调用方从该列读入并显式传入。</p>
 *
 * <p>不可变 record：构造后字段不可改写。</p>
 *
 * @param version 密钥版本号（对应 {@code key_version TINYINT} 列）
 * @param key     原始密钥字节（32 字节 = AES-256）
 */
public record MasterKey(int version, byte[] key) {

    /** AES-256 密钥长度（字节）= 256 bit。 */
    private static final int AES_256_KEY_BYTES = 32;

    /** 算法标识（JCE 标准名）。 */
    private static final String ALGORITHM = "AES";

    /**
     * 从 JSON 绑定态的字符串构造 {@link MasterKey}。
     *
     * <p>解析策略同 {@link Pepper#of(int, String)}：先试 hex，失败再试 base64。</p>
     *
     * @param version 密钥版本号（对应 {@code key_version} 列）
     * @param key     密钥字符串（hex 或 base64）
     * @return {@link MasterKey} 实例
     * @throws IllegalArgumentException 密钥长度非 32 字节时抛出
     */
    public static MasterKey of(int version, String key) {
        byte[] bytes = KeyEncodings.decode(key);
        if (bytes.length != AES_256_KEY_BYTES) {
            throw new IllegalArgumentException(
                    "AEAD 主密钥长度须为 " + AES_256_KEY_BYTES + " 字节（AES-256），实际 " + bytes.length);
        }
        return new MasterKey(version, bytes);
    }

    /**
     * 获取 JCE {@link SecretKey}（每次从原始字节构建）。
     *
     * <p>为什么每次构建：record 不允许非组件实例字段（编译期约束），
     * 且 {@link SecretKeySpec} 构造极轻量（数组拷贝 + 算法名），热路径开销可忽略。</p>
     *
     * @return {@link SecretKey} 实例（AES/256 bit）
     */
    public SecretKey secretKey() {
        return new SecretKeySpec(key, ALGORITHM);
    }
}
