package com.s2s.server.common.crypto;

/**
 * HMAC pepper 条目（详设 §4.1 三列范式；安全 §4：盲索引的 HMAC-SHA256 密钥，按版本轮换）。
 *
 * <p>JSON 形态（与 {@code SecretsProperties.hmacPeppersJson} 绑定源一致）：
 * {@code [{"version":1,"key":"<32字节hex或base64>"}]}。</p>
 *
 * <p>{@link #version()} 与数据库 {@code key_version TINYINT} 列一一对应——
 * 详设 §4.1 把版本号定义为<b>独立列</b>而非编码进密文/哈希，故此处用数值而非字符串标识。</p>
 *
 * <p>不可变 record：构造后字段不可改写，杜绝运行期被篡改。</p>
 *
 * @param version 密钥版本号（对应 {@code key_version TINYINT} 列）
 * @param key     原始密钥字节（HMAC-SHA256 密钥）
 */
public record Pepper(int version, byte[] key) {

    /**
     * 从 JSON 绑定态的字符串构造 {@link Pepper}。
     *
     * <p>为什么接受 hex/base64 两种编码：早期原型用 hex，后改 base64 更紧凑；
     * 本方法先试 hex（偶数长度且全为十六进制字符），失败再试 base64，
     * 由启动期解析器负责最终校验（宽容解析避免启动失败）。</p>
     *
     * @param version 密钥版本号（对应 {@code key_version} 列）
     * @param key     密钥字符串（hex 或 base64）
     * @return {@link Pepper} 实例
     * @throws IllegalArgumentException 两种编码均解析失败时抛出
     */
    public static Pepper of(int version, String key) {
        return new Pepper(version, KeyEncodings.decode(key));
    }
}
