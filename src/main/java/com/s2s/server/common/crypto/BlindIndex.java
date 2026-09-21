package com.s2s.server.common.crypto;

import java.nio.charset.StandardCharsets;
import java.util.List;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 盲索引原语（详设 §4.1 三列范式的 {@code xxx_hash} 列；承载 {@code user_identity.identity_hash}）。
 *
 * <p>为什么用 HMAC 而非裸 SHA-256：裸哈希对字典攻击零防御——手机号空间有限（11 位数字约 100 亿），
 * 彩虹表可秒破。HMAC 引入 pepper（服务端保管的随机密钥）后，攻击者须同时拿到 pepper 才能离线破解，
 * 把「拖库即破」升级为「拖库 + 泄露密钥文件」双条件。</p>
 *
 * <p>确定性：同一 {@code phone} + 同一 pepper 永远产出同一结果，
 * 这是承载 {@code user_identity.uk_type_hash} 唯一索引的前提（AEAD 密文因随机 IV 不可建唯一索引）。</p>
 *
 * <p>输出形态：32 字节原始 HMAC-SHA256，直接对应数据库 {@code BINARY(32)} 列
 * （详设 §4.1）。<b>刻意不返回十六进制字符串</b>——返回 hex 则调用方须在 SQL 里 {@code UNHEX()}，
 * 或在实体上做类型转换，多一层易错的转换点；返回 {@code byte[]} 让 JDBC/MyBatis 直接映射 {@code BINARY(32)}。</p>
 *
 * <p>线程安全：本类无状态（纯函数），可并发调用。</p>
 */
public final class BlindIndex {

    /** HMAC-SHA256 算法标识（JCE 标准名）。 */
    private static final String HMAC_SHA256 = "HmacSHA256";

    /** 私有构造器：纯工具类，禁止实例化。 */
    private BlindIndex() {
        throw new AssertionError("BlindIndex is a utility class");
    }

    /**
     * 计算手机号的盲索引（HMAC-SHA256 + 列表中版本最高的 pepper）。
     *
     * <p>pepper 选取规则：取列表中 {@link Pepper#version()} <b>最大</b>者（最新版本）。
     * 为什么按 version 而非列表位置：列表顺序依赖 JSON 书写顺序这一隐式约定，
     * 而 version 是显式声明的数值——按数值取最大可避免「JSON 里版本写反了」这类静默错误。</p>
     *
     * <p>轮换语义：新数据一律用最新 pepper 生成索引；旧数据的索引仍由旧 pepper 生成，
     * 故查询旧数据需按 {@link #hmac(String, Pepper)} 逐个 pepper 试（见该方法说明）。</p>
     *
     * @param phone   手机号明文（11 位中国大陆手机号）
     * @param peppers HMAC pepper 列表（非空）
     * @return 32 字节 HMAC-SHA256 值，直接落 {@code BINARY(32)}
     * @throws IllegalArgumentException peppers 为 null 或空时抛出
     * @throws IllegalStateException    HMAC 初始化失败时抛出（JCE 环境异常，不应发生）
     */
    public static byte[] hmac(String phone, List<Pepper> peppers) {
        if (peppers == null || peppers.isEmpty()) {
            throw new IllegalArgumentException("peppers 列表不可为空（编码规范 §3.3：密钥列表启动期已校验）");
        }
        Pepper latest = peppers.get(0);
        for (Pepper candidate : peppers) {
            if (candidate.version() > latest.version()) {
                latest = candidate;
            }
        }
        return hmac(phone, latest);
    }

    /**
     * 计算手机号的盲索引（指定 pepper，用于跨版本验证场景）。
     *
     * <p>典型用途：pepper 轮换后的过渡期内，先按最新 pepper 查索引；
     * 未命中则遍历旧 pepper 重查（旧数据仍由旧 pepper 生成索引）。
     * 本方法为该遍历提供单 pepper 入口。</p>
     *
     * @param phone  手机号明文
     * @param pepper 指定 pepper
     * @return 32 字节 HMAC-SHA256 值
     * @throws IllegalStateException HMAC 初始化失败时抛出（JCE 环境异常，不应发生）
     */
    public static byte[] hmac(String phone, Pepper pepper) {
        try {
            Mac mac = Mac.getInstance(HMAC_SHA256);
            mac.init(new SecretKeySpec(pepper.key(), HMAC_SHA256));
            return mac.doFinal(phone.getBytes(StandardCharsets.UTF_8));
        } catch (java.security.NoSuchAlgorithmException exception) {
            // HmacSHA256 是 JCE 强制要求实现的算法，此处不应到达
            throw new IllegalStateException("HMAC-SHA256 算法不可用（JCE 环境异常）", exception);
        } catch (java.security.InvalidKeyException exception) {
            // pepper.key() 长度合法（启动期已校验），此处不应到达
            throw new IllegalStateException("HMAC 密钥非法", exception);
        }
    }
}
