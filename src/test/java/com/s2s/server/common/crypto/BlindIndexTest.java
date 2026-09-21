package com.s2s.server.common.crypto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@link BlindIndex} 对账守门测试（[123] U1；详设 §4.1「三列范式」）。
 *
 * <p>职责：把盲索引原语从人眼评审转为逐项断言——确定性、输出长度、版本选取、空列表守卫，
 * 任一行为漂移都会让本测试红。</p>
 *
 * <p>出处：详设 §4.1（{@code xxx_hash BINARY(32)}，HMAC-SHA256+pepper）；
 * 安全 §4（pepper 保管与轮换）。</p>
 */
class BlindIndexTest {

    /** 旧版 pepper（version=1）与新版 pepper（version=2），模拟轮换过渡期。 */
    private static final Pepper PEPPER_V1 =
            Pepper.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    /** 新版 pepper，版本号更大。 */
    private static final Pepper PEPPER_V2 =
            Pepper.of(2, "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");

    /** 正序列表（旧版在前）——验证「按 version 取最大」而非「取列表末位」。 */
    private static final List<Pepper> PEPPERS_ASC = List.of(PEPPER_V1, PEPPER_V2);

    /** 倒序列表（新版在前）——与正序列表结果必须一致。 */
    private static final List<Pepper> PEPPERS_DESC = List.of(PEPPER_V2, PEPPER_V1);

    /**
     * 确定性：同一 phone + 同一 pepper 永远产出同一 32 字节值。
     * 这是承载 {@code user_identity.uk_type_hash} 唯一索引的前提。
     *
     * @return void；断言失败即 HMAC 实现非确定性
     */
    @Test
    void hmacIsDeterministic() {
        byte[] first = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        byte[] second = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        assertThat(first).isEqualTo(second);
    }

    /**
     * 输出形态：32 字节，直接对应数据库 {@code BINARY(32)} 列。
     *
     * @return void；断言失败即输出长度与 schema 列宽不符
     */
    @Test
    void hmacOutputIs32Bytes() {
        byte[] hash = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        assertThat(hash).hasSize(32);
    }

    /**
     * 不同手机号产出不同结果（雪崩效应：1 位差异 → 输出全变）。
     *
     * @return void；断言失败即 HMAC 雪崩效应失效
     */
    @Test
    void differentPhonesProduceDifferentHashes() {
        byte[] first = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        byte[] second = BlindIndex.hmac("13800138001", PEPPERS_ASC);
        assertThat(first).isNotEqualTo(second);
    }

    /**
     * pepper 轮换：新旧 pepper 产出不同结果（旧数据需用旧 pepper 重新生成索引才能命中）。
     *
     * @return void；断言失败即轮换后新旧数据无法区分
     */
    @Test
    void differentPeppersProduceDifferentHashes() {
        byte[] oldHash = BlindIndex.hmac("13800138000", PEPPER_V1);
        byte[] newHash = BlindIndex.hmac("13800138000", PEPPER_V2);
        assertThat(oldHash).isNotEqualTo(newHash);
    }

    /**
     * 默认取<b>版本号最高</b>的 pepper（而非列表位置）。
     *
     * @return void；断言失败即版本选取规则错误
     */
    @Test
    void hmacUsesHighestVersionPepper() {
        byte[] fromList = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        byte[] fromV2 = BlindIndex.hmac("13800138000", PEPPER_V2);
        assertThat(fromList).isEqualTo(fromV2);
    }

    /**
     * 列表书写顺序不影响结果（正序/倒序同值）——证明实现按 version 取值而非按索引。
     *
     * @return void；断言失败即实现依赖了列表顺序这一隐式约定
     */
    @Test
    void hmacIsIndependentOfListOrder() {
        byte[] ascending = BlindIndex.hmac("13800138000", PEPPERS_ASC);
        byte[] descending = BlindIndex.hmac("13800138000", PEPPERS_DESC);
        assertThat(ascending).isEqualTo(descending);
    }

    /**
     * 空 pepper 列表守卫：启动期已校验，但防御性编程仍须拦截。
     *
     * @return void；断言失败即空列表未拦截
     */
    @Test
    void hmacRejectsEmptyPeppers() {
        assertThatThrownBy(() -> BlindIndex.hmac("13800138000", List.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("peppers");
    }

    /**
     * null pepper 列表守卫。
     *
     * @return void；断言失败即 null 未拦截
     */
    @Test
    void hmacRejectsNullPeppers() {
        assertThatThrownBy(() -> BlindIndex.hmac("13800138000", (List<Pepper>) null))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
