package com.s2s.server.admin;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * {@link AdminPasswordHasher} 单元测试（[153] B2-5）。
 *
 * <p>覆盖四件「错了不会崩、但会让后台门户洞开或全员登不进」的事：
 * 正确口令可校验、错误口令被拒、非法存储串不误判为通过、盐随机化使同口令哈希不同。</p>
 */
class AdminPasswordHasherTest {

    /** 被测哈希器（无依赖，直接实例化）。 */
    private final AdminPasswordHasher hasher = new AdminPasswordHasher();

    /**
     * 正确口令 → 校验通过。
     *
     * @return void；断言失败即登录链断裂
     */
    @Test
    void hashThenMatchesReturnsTrue() {
        String stored = hasher.hash("S3cret-Pass!");
        assertThat(hasher.matches("S3cret-Pass!", stored)).isTrue();
    }

    /**
     * 错误口令 → 校验不通过。
     *
     * @return void；断言失败即任意口令可登录
     */
    @Test
    void wrongPasswordDoesNotMatch() {
        String stored = hasher.hash("S3cret-Pass!");
        assertThat(hasher.matches("wrong", stored)).isFalse();
    }

    /**
     * 非法/空存储串 → 返回 false 而非抛异常（登录失败是业务结果，不是故障）。
     *
     * @return void；断言失败即脏数据把登录打成 500
     */
    @Test
    void malformedStoredValueReturnsFalse() {
        assertThat(hasher.matches("x", "not-a-hash")).isFalse();
        assertThat(hasher.matches("x", "pbkdf2$abc$def")).isFalse();
        assertThat(hasher.matches("x", null)).isFalse();
        assertThat(hasher.matches(null, "pbkdf2$1$a$b")).isFalse();
    }

    /**
     * 存储串格式与随机盐：前缀固定、同口令两次哈希不同（盐随机）。
     *
     * @return void；断言失败即盐未随机（彩虹表可复用）
     */
    @Test
    void hashFormatAndRandomSalt() {
        String first = hasher.hash("same");
        String second = hasher.hash("same");
        assertThat(first).startsWith("pbkdf2$");
        assertThat(first).isNotEqualTo(second);
    }
}
