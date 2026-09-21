package com.s2s.server.common.crypto;

import java.nio.charset.StandardCharsets;

/**
 * 密钥字符串编码解码工具（hex / base64 双格式宽容解析）。
 *
 * <p>为什么需要它：pepper 与主密钥的 JSON 值历史上有两种编码（早期 hex、后期 base64），
 * 解析器需同时兼容，否则换编码就要动密钥文件。本类把该宽容逻辑收敛到一处，
 * {@link Pepper} 与 {@link MasterKey} 共用，避免两处实现漂移。</p>
 *
 * <p>包内可见：仅加解密包内部使用，不对外暴露。</p>
 */
final class KeyEncodings {

    /** 十六进制字符集（小写），用于 hex 格式判定。 */
    private static final String HEX_CHARS = "0123456789abcdefABCDEF";

    /** 私有构造器：纯工具类，禁止实例化。 */
    private KeyEncodings() {
        throw new AssertionError("KeyEncodings is a utility class");
    }

    /**
     * 解码密钥字符串：先按 hex 解析，失败则按 base64 解析。
     *
     * <p>hex 判定条件：非空、长度为偶数、且全部字符属于十六进制字符集。
     * 之所以先试 hex：base64 的合法字符集<b>包含</b>纯十六进制串（如 {@code "abcdef12"} 既是合法 hex
     * 也是合法 base64），若先试 base64 会把本应是 hex 的密钥解成完全不同的字节。</p>
     *
     * @param key 密钥字符串（hex 或 base64）
     * @return 原始密钥字节
     * @throws IllegalArgumentException 两种编码均解析失败时抛出
     */
    static byte[] decode(String key) {
        if (key == null || key.isEmpty()) {
            throw new IllegalArgumentException("密钥字符串不可为空");
        }
        if (isHex(key)) {
            return fromHex(key);
        }
        try {
            return java.util.Base64.getDecoder().decode(key);
        } catch (IllegalArgumentException exception) {
            throw new IllegalArgumentException("密钥既非合法 hex 也非合法 base64", exception);
        }
    }

    /**
     * 判定字符串是否为纯十六进制表示。
     *
     * @param value 待判定字符串
     * @return 偶数长度且字符全属十六进制字符集时 {@code true}
     */
    private static boolean isHex(String value) {
        if (value.length() % 2 != 0) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            if (HEX_CHARS.indexOf(value.charAt(i)) < 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * 十六进制字符串转字节数组（调用前须经 {@link #isHex} 判定）。
     *
     * @param hex 十六进制字符串（长度偶数）
     * @return 字节数组
     */
    private static byte[] fromHex(String hex) {
        byte[] bytes = new byte[hex.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return bytes;
    }

    /**
     * 字节数组转小写十六进制字符串（无分隔符）。
     *
     * <p>用途：日志与调试输出。为什么不用 {@code javax.xml.bind.DatatypeConverter}：
     * Java 11 起该 API 移出 JDK，为一个小工具引入依赖不划算。</p>
     *
     * @param bytes 待转换字节数组
     * @return 小写十六进制字符串（长度为 {@code bytes.length * 2}）
     */
    static String toHex(byte[] bytes) {
        char[] hex = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 0xFF;
            hex[i * 2] = "0123456789abcdef".charAt(value >>> 4);
            hex[i * 2 + 1] = "0123456789abcdef".charAt(value & 0x0F);
        }
        return new String(hex);
    }

    /**
     * 把 AAD 材料按 UTF-8 转为字节数组（供 AEAD 附加认证数据使用）。
     *
     * @param aad 附加认证数据字符串
     * @return UTF-8 字节数组；{@code aad} 为 null 时返回空数组
     */
    static byte[] aadBytes(String aad) {
        return aad == null ? new byte[0] : aad.getBytes(StandardCharsets.UTF_8);
    }
}
