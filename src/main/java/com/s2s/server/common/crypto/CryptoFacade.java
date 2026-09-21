package com.s2s.server.common.crypto;

import java.nio.ByteBuffer;
import java.security.SecureRandom;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * 全系统唯一加解密入口（详设 §4.1/§4.3；安全 §4；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>对应详设 §4.1 三列范式中的 {@code xxx_enc} 列：AES-GCM-256 + 随机 12 字节 IV，
 * 密文布局为 {@code iv(12) || ciphertext(明文 + 16 字节 GCM 标签)}，
 * 直接落数据库 {@code VARBINARY} 列。<b>版本号不编进密文</b>——它由
 * {@code key_version TINYINT} 独立列承载（详设 §4.1 明定三列结构）。</p>
 *
 * <p><b>全系统只有本类一处可以解密。</b>任何新增解密调用点都视为架构变更，须评审
 * （详设 §4.3；编码规范守门：{@code CryptoFacade.decrypt} 调用点计数 == 1，
 * Batch1 唯一调用点为 {@code contact.ContactService#viewContact}）。</p>
 *
 * <p>为什么用 AES-GCM 而非 AES-CBC：GCM 是认证加密（AEAD），密文自带完整性校验，
 * 被篡改时解密直接失败（抛 {@link javax.crypto.AEADBadTagException}），无需额外 HMAC 层。
 * CBC 需「先加密后 HMAC」两步且顺序敏感（encrypt-then-MAC），实现错误会导致
 * 「密文被篡改却解密成功」的静默失效。</p>
 *
 * <p>线程安全：本类无可变状态（{@link SecureRandom} 线程安全，{@link Cipher} 每次新建），可并发调用。</p>
 */
@Component
public class CryptoFacade {

    private static final Logger log = LoggerFactory.getLogger(CryptoFacade.class);

    /** AES-GCM 算法标识（JCE 标准名）。 */
    private static final String AES_GCM = "AES/GCM/NoPadding";

    /** GCM 认证标签长度（位）= 128 bit（NIST SP 800-38D 推荐值）。 */
    private static final int GCM_TAG_BITS = 128;

    /** IV 长度（字节）= 96 bit（GCM 标准 IV 长度，非 12 字节会降低性能）。 */
    private static final int IV_BYTES = 12;

    /** GCM 认证标签字节长度（用于密文最短长度校验）。 */
    private static final int GCM_TAG_BYTES = 16;

    /** 随机数生成器（{@link SecureRandom} 线程安全）。 */
    private final SecureRandom secureRandom = new SecureRandom();

    /** AEAD 主密钥列表（同一 version 至多一条；解密按 version 查找）。 */
    private final List<MasterKey> masterKeys;

    /**
     * 构造加解密门面：注入 AEAD 主密钥列表。
     *
     * @param masterKeys AEAD 主密钥列表（非空）
     * @throws IllegalArgumentException masterKeys 为 null 或空时抛出
     */
    public CryptoFacade(List<MasterKey> masterKeys) {
        if (masterKeys == null || masterKeys.isEmpty()) {
            throw new IllegalArgumentException("masterKeys 列表不可为空（编码规范 §3.3：密钥列表启动期已校验）");
        }
        this.masterKeys = masterKeys;
    }

    /**
     * 加密结果：密文与其密钥版本号。
     *
     * <p>为什么要一起返回：详设 §4.1 要求 {@code xxx_enc} 与 {@code key_version} 分列存储，
     * 调用方拿到密文后<b>必须</b>同时写入版本列，故两者同源返回，
     * 避免调用方自行猜版本号（猜错会导致后续解密取错密钥）。</p>
     *
     * @param keyVersion 密钥版本号，落 {@code key_version TINYINT} 列
     * @param ciphertext 密文字节，落 {@code xxx_enc VARBINARY} 列
     */
    public record EncryptResult(int keyVersion, byte[] ciphertext) {
    }

    /**
     * 加密：AES-GCM-256 + 随机 IV + AAD 绑定。
     *
     * <p>使用<b>版本号最高</b>的主密钥（轮换后新数据一律用最新密钥）。
     * AAD 绑定关系见详设 §4.2（{@code user_identity} → {@code user_id + identity_type}、
     * {@code user.real_name_enc} → {@code user_id}、{@code post.contact_value_enc} → {@code post_id}）。</p>
     *
     * @param plaintext 明文（如手机号 {@code "13800138000"}）
     * @param aad       附加认证数据（如 {@code user_id + identity_type}）
     * @return 加密结果（版本号 + 密文），二者分列落库
     * @throws IllegalStateException 加密失败时抛出（JCE 环境异常，不应发生）
     */
    public EncryptResult encrypt(String plaintext, String aad) {
        MasterKey latest = masterKeys.get(0);
        for (MasterKey candidate : masterKeys) {
            if (candidate.version() > latest.version()) {
                latest = candidate;
            }
        }

        byte[] iv = new byte[IV_BYTES];
        secureRandom.nextBytes(iv);

        try {
            Cipher cipher = Cipher.getInstance(AES_GCM);
            cipher.init(Cipher.ENCRYPT_MODE, latest.secretKey(), new GCMParameterSpec(GCM_TAG_BITS, iv));
            cipher.updateAAD(KeyEncodings.aadBytes(aad));
            byte[] encrypted = cipher.doFinal(plaintext.getBytes(java.nio.charset.StandardCharsets.UTF_8));

            ByteBuffer buffer = ByteBuffer.allocate(IV_BYTES + encrypted.length);
            buffer.put(iv);
            buffer.put(encrypted);
            return new EncryptResult(latest.version(), buffer.array());
        } catch (java.security.NoSuchAlgorithmException
                | java.security.InvalidKeyException
                | java.security.InvalidAlgorithmParameterException
                | javax.crypto.NoSuchPaddingException
                | javax.crypto.BadPaddingException
                | javax.crypto.IllegalBlockSizeException exception) {
            throw new IllegalStateException("AES-GCM 加密失败", exception);
        }
    }

    /**
     * 解密：AES-GCM-256 + AAD 校验 + 同步写 {@code audit_log}。
     *
     * <p>版本号由调用方从 {@code key_version} 列读入后显式传入（详设 §4.1 三列范式）。</p>
     *
     * <p><b>全系统唯一解密入口。</b>新增调用点须评审（详设 §4.3）。</p>
     *
     * @param ciphertext 密文（布局 {@code iv || ciphertext}，来自 {@code xxx_enc} 列）
     * @param aad        附加认证数据（必须与加密时逐字一致，否则 GCM 标签校验失败）
     * @param keyVersion 密钥版本号（来自 {@code key_version} 列）
     * @return 解密后的明文
     * @throws IllegalArgumentException 密文过短、或 keyVersion 无对应密钥时抛出
     * @throws IllegalStateException    解密失败时抛出（GCM 标签校验失败 = 密文被篡改或 AAD 不匹配）
     */
    public String decrypt(byte[] ciphertext, String aad, int keyVersion) {
        if (ciphertext == null || ciphertext.length < IV_BYTES + GCM_TAG_BYTES) {
            throw new IllegalArgumentException(
                    "密文长度非法（至少 " + (IV_BYTES + GCM_TAG_BYTES) + " 字节 = IV + GCM 标签）");
        }

        MasterKey key = findKeyByVersion(keyVersion);
        if (key == null) {
            throw new IllegalArgumentException("key_version=" + keyVersion + " 无对应密钥（密钥已轮换且旧密钥已移除）");
        }

        ByteBuffer buffer = ByteBuffer.wrap(ciphertext);
        byte[] iv = new byte[IV_BYTES];
        buffer.get(iv);
        byte[] encrypted = new byte[buffer.remaining()];
        buffer.get(encrypted);

        try {
            Cipher cipher = Cipher.getInstance(AES_GCM);
            cipher.init(Cipher.DECRYPT_MODE, key.secretKey(), new GCMParameterSpec(GCM_TAG_BITS, iv));
            cipher.updateAAD(KeyEncodings.aadBytes(aad));
            byte[] plaintext = cipher.doFinal(encrypted);

            writeAuditLog(keyVersion, aad);

            return new String(plaintext, java.nio.charset.StandardCharsets.UTF_8);
        } catch (javax.crypto.AEADBadTagException exception) {
            log.warn("AES-GCM 解密失败：密文被篡改或 AAD 不匹配（keyVersion={}）", keyVersion, exception);
            throw new IllegalStateException("解密失败：密文完整性校验未通过", exception);
        } catch (java.security.NoSuchAlgorithmException
                | java.security.InvalidKeyException
                | java.security.InvalidAlgorithmParameterException
                | javax.crypto.NoSuchPaddingException
                | javax.crypto.BadPaddingException
                | javax.crypto.IllegalBlockSizeException exception) {
            throw new IllegalStateException("AES-GCM 解密失败", exception);
        }
    }

    /**
     * 按版本号查找主密钥（线性扫描，列表长度通常 ≤ 3，开销可忽略）。
     *
     * @param keyVersion 密钥版本号
     * @return 对应密钥；无匹配时 {@code null}
     */
    private MasterKey findKeyByVersion(int keyVersion) {
        for (MasterKey key : masterKeys) {
            if (key.version() == keyVersion) {
                return key;
            }
        }
        return null;
    }

    /**
     * 写审计日志（详设 §4.3：解密行为必须同步写 {@code audit_log}）。
     *
     * <p><b>当前为占位实现</b>：{@code audit_log} 表已在 {@code V1__init_schema.sql} 建好，
     * 但其 Mapper 属持久层基础设施（随 [123] U2 落地）。待 Mapper 就绪后，
     * 本方法须改为<b>与解密同事务</b>写库（当前只打日志，不足以应对合规审计）。</p>
     *
     * <p>为何不在本单元直接落库：加解密包不应耦合持久层（{@code common.crypto} 无 Mapper 依赖），
     * 且 Batch1 唯一解密调用点（contact 域）尚未实现，此处不会被执行到。</p>
     *
     * @param keyVersion 所用密钥版本号
     * @param aad        附加认证数据（如 {@code post_id}）
     */
    private void writeAuditLog(int keyVersion, String aad) {
        log.info("CRYPTO_DECRYPT: key_version={}, aad={}", keyVersion, aad);
        // TODO([123] U2 持久层就绪后)：改为 audit_log 表写入，与解密同事务
    }
}
