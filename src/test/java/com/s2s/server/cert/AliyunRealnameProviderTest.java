package com.s2s.server.cert;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link AliyunRealnameProvider} 的形态与快速失败单测（不触网）。
 *
 * <p>覆盖三件事：dry-run 的判定规则、真实模式下 AK 缺失时启动即失败、
 * dry-run 模式下允许 AK 为空（当前生产默认形态）。</p>
 */
class AliyunRealnameProviderTest {

    /** dry-run 端点占位（dry-run 下不会被使用）。 */
    private static final String ENDPOINT = "https://cloudauth.cn-beijing.aliyuncs.com";

    @Test
    @DisplayName("dry-run：身份证末 4 位 0000 判通过")
    void dryRunPassesSuffix0000() {
        final AliyunRealnameProvider provider =
                new AliyunRealnameProvider(true, ENDPOINT, "", "");
        assertTrue(provider.verify("张三", "110101199001010000"));
    }

    @Test
    @DisplayName("dry-run：其余身份证号判不通过")
    void dryRunRejectsOtherSuffix() {
        final AliyunRealnameProvider provider =
                new AliyunRealnameProvider(true, ENDPOINT, "", "");
        assertFalse(provider.verify("张三", "110101199001011234"));
    }

    @Test
    @DisplayName("真实模式：AK 缺失时构造即失败（拒绝空凭据启动）")
    void realModeWithoutAccessKeyFailsFast() {
        assertThrows(IllegalStateException.class,
                () -> new AliyunRealnameProvider(false, ENDPOINT, "", ""));
    }
}
