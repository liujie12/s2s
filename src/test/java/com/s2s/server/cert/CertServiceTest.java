package com.s2s.server.cert;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * {@link CertService} 空壳测试（[123] U9；plan U9 验收「恒返回 NONE」）。
 *
 * <p>覆盖场景：{@code getRealnameStatus(userId)} 对任意用户恒返回 {@code "none"}，
 * 验证 Batch1 实名状态恒未实名的口径（cert 域 Batch2 才实现真实核验）。</p>
 */
class CertServiceTest {

    /**
     * 场景一：任意用户实名状态恒为 none。
     *
     * @return void
     */
    @Test
    void getRealnameStatusAlwaysReturnsNone() {
        CertService certService = new CertService();

        assertThat(certService.getRealnameStatus(1L)).isEqualTo(CertService.REALNAME_STATUS_NONE);
        assertThat(certService.getRealnameStatus(999L)).isEqualTo("none");
    }
}
