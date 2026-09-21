package com.s2s.server.common.crypto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link CryptoFacade} 对账守门测试（[123] U1；详设 §4.1「三列范式」）。
 *
 * <p>职责：把加解密原语从人眼评审转为逐项断言——往返一致性、AAD 绑定、
 * 版本号路由、密文格式校验，任一行为漂移都会让本测试红。</p>
 *
 * <p>出处：详设 §4.1（{@code xxx_enc VARBINARY} + {@code key_version TINYINT}）、
 * §4.2（AAD 绑定表）、§4.3（解密入口收敛）。</p>
 */
class CryptoFacadeTest {

    /** 旧版主密钥（version=1）。 */
    private static final MasterKey KEY_V1 =
            MasterKey.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    /** 新版主密钥（version=2）。 */
    private static final MasterKey KEY_V2 =
            MasterKey.of(2, "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");

    /** 倒序列表（新版在前）——验证「按 version 取最大」而非「取列表末位」。 */
    private static final List<MasterKey> MASTER_KEYS = List.of(KEY_V2, KEY_V1);

    private CryptoFacade cryptoFacade;

    /**
     * 每个测试前重建门面（无状态，但隔离性更好）。
     *
     * @return void；无断言
     */
    @BeforeEach
    void setUp() {
        cryptoFacade = new CryptoFacade(MASTER_KEYS);
    }

    /**
     * 往返一致性：加密后解密必须还原明文。
     *
     * @return void；断言失败即加解密原语实现错误
     */
    @Test
    void encryptDecryptRoundtrip() {
        String plaintext = "13800138000";
        String aad = "1001:phone";
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt(plaintext, aad);
        assertThat(cryptoFacade.decrypt(result.ciphertext(), aad, result.keyVersion())).isEqualTo(plaintext);
    }

    /**
     * 加密使用的是<b>版本号最高</b>的密钥（轮换后新数据一律用最新密钥）。
     *
     * @return void；断言失败即密钥选取规则错误（会导致新数据被旧密钥加密）
     */
    @Test
    void encryptUsesHighestVersionKey() {
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt("13800138000", "1001:phone");
        assertThat(result.keyVersion()).isEqualTo(2);
    }

    /**
     * 密文长度 = IV(12) + 明文长度 + GCM 标签(16)。
     * 该断言锁定密文布局，防止把版本号等元数据混编进密文。
     *
     * @return void；断言失败即密文布局偏离详设 §4.1
     */
    @Test
    void ciphertextLayoutIsIvPlusCiphertext() {
        String plaintext = "13800138000";
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt(plaintext, "1001:phone");
        assertThat(result.ciphertext()).hasSize(12 + plaintext.getBytes(java.nio.charset.StandardCharsets.UTF_8).length + 16);
    }

    /**
     * 版本号路由：用旧版本号解新密钥加密的密文必须失败。
     * 这是「版本列与密文必须同源写入」守门的反向验证。
     *
     * @return void；断言失败即 key_version 未参与密钥路由
     */
    @Test
    void wrongKeyVersionCausesDecryptionFailure() {
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt("13800138000", "1001:phone");
        assertThatThrownBy(() -> cryptoFacade.decrypt(result.ciphertext(), "1001:phone", 1))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("完整性");
    }

    /**
     * 未配置的版本号必须显式报错（而非静默取错密钥）。
     *
     * @return void；断言失败即未知版本被静默容忍
     */
    @Test
    void unknownKeyVersionIsRejected() {
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt("13800138000", "1001:phone");
        assertThatThrownBy(() -> cryptoFacade.decrypt(result.ciphertext(), "1001:phone", 99))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("key_version=99");
    }

    /**
     * AAD 绑定：加密与解密 AAD 不一致时，GCM 标签校验必须失败。
     * 这是 {@code user_identity.identity_value_enc} 与 {@code user_id + identity_type}
     * 强绑定的安全基石（详设 §4.2）。
     *
     * @return void；断言失败即 AAD 绑定失效
     */
    @Test
    void aadMismatchCausesDecryptionFailure() {
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt("13800138000", "1001:phone");
        assertThatThrownBy(() -> cryptoFacade.decrypt(result.ciphertext(), "1002:phone", result.keyVersion()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("完整性");
    }

    /**
     * 密文过短必须拦截（防止后续切片越界）。
     *
     * @return void；断言失败即格式校验缺失
     */
    @Test
    void tooShortCiphertextIsRejected() {
        assertThatThrownBy(() -> cryptoFacade.decrypt(new byte[]{1, 2}, "aad", 2))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("密文长度非法");
    }

    /**
     * null 密文必须拦截。
     *
     * @return void；断言失败即 null 未拦截
     */
    @Test
    void nullCiphertextIsRejected() {
        assertThatThrownBy(() -> cryptoFacade.decrypt(null, "aad", 2))
                .isInstanceOf(IllegalArgumentException.class);
    }

    /**
     * 随机 IV：同一明文 + 同一 AAD 多次加密产出不同密文。
     * 这是 GCM 安全性前提（IV 重用 = 密钥流重用 = 明文泄露）。
     *
     * @return void；断言失败即 IV 非随机
     */
    @Test
    void samePlaintextProducesDifferentCiphertexts() {
        CryptoFacade.EncryptResult first = cryptoFacade.encrypt("13800138000", "1001:phone");
        CryptoFacade.EncryptResult second = cryptoFacade.encrypt("13800138000", "1001:phone");
        assertThat(first.ciphertext()).isNotEqualTo(second.ciphertext());
    }

    /**
     * 空明文可加密（边界场景：不应发生但须不崩溃）。
     *
     * @return void；断言失败即空明文处理异常
     */
    @Test
    void emptyPlaintextCanBeEncrypted() {
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt("", "1001:phone");
        assertThat(cryptoFacade.decrypt(result.ciphertext(), "1001:phone", result.keyVersion())).isEmpty();
    }

    /**
     * null AAD 可加解密（详设 §4.2 未列 null 场景，但实现须保持一致且不崩溃）。
     *
     * @return void；断言失败即 null AAD 处理异常
     */
    @Test
    void nullAadCanBeEncryptedAndDecrypted() {
        String plaintext = "13800138000";
        CryptoFacade.EncryptResult result = cryptoFacade.encrypt(plaintext, null);
        assertThat(cryptoFacade.decrypt(result.ciphertext(), null, result.keyVersion())).isEqualTo(plaintext);
    }

    /**
     * 空密钥列表守卫：启动期已校验，但防御性编程仍须拦截。
     *
     * @return void；断言失败即空列表未拦截
     */
    @Test
    void constructorRejectsEmptyMasterKeys() {
        assertThatThrownBy(() -> new CryptoFacade(List.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("masterKeys");
    }

    /**
     * null 密钥列表守卫。
     *
     * @return void；断言失败即 null 未拦截
     */
    @Test
    void constructorRejectsNullMasterKeys() {
        assertThatThrownBy(() -> new CryptoFacade(null))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
