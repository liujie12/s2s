package com.s2s.server.common.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Properties;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.core.io.ClassPathResource;

/**
 * application.yml 关键口径守门测试（U-5）。
 *
 * 把「响应体无堆栈」与「六类凭证硬占位变量名」从人眼评审转为会失败的自动化：
 * {@link YamlPropertiesFactoryBean} 只解析 YAML 结构、不展开 ${} 占位，
 * 因此可以直接断言占位字面量与预期环境变量名逐字一致——这也是 application.yml 与
 * 仓库根 .env.example 双向核对在测试层的镜像（grep 核对见 U-5 验证闸门）。
 *
 * <p>[122] U1 扩展：forward-headers-strategy（KTD2 真实客户端 IP 口径）与
 * jwt-secret 占位（KTD10，占位断言八处加到九处）纳入守门。</p>
 */
class ApplicationYamlTest {

    /**
     * 加载 jar 内 application.yml 为 Properties（不展开占位）。
     *
     * @return 扁平键属性集；${} 占位保持字面量
     */
    private static Properties loadApplicationYaml() {
        YamlPropertiesFactoryBean factory = new YamlPropertiesFactoryBean();
        factory.setResources(new ClassPathResource("application.yml"));
        return factory.getObject();
    }

    /**
     * 断言 {@code server.error.include-stacktrace} 固定为 {@code never}。
     * 依据：编码规范 §4.3「日志打全栈、响应体无堆栈」+ 详设 §2.2；
     * 本项是 GlobalExceptionHandler 之外对 /error 路径的配置层双保险。
     *
     * @return void；断言失败即有人改动了无堆栈口径
     */
    @Test
    void errorResponseNeverIncludesStacktrace() {
        assertThat(loadApplicationYaml().getProperty("server.error.include-stacktrace"))
                .isEqualTo("never");
    }

    /**
     * 断言 {@code server.forward-headers-strategy} 固定为 {@code framework}（[122] KTD2）。
     * 依据：Caddy 反代后 IP 维限频三轨（rl:sms:ip / rl:contact:ip / rl:guestdetail:ip）
     * 必须取真实客户端 IP，不配则全站共享 Caddy 容器 IP，上线即故障；framework 策略
     * 无 X-Forwarded-For 头时回退 remoteAddr，本地直连开发兼容。安全前提：Caddy
     * 覆盖式 header_up X-Forwarded-For {remote_host}（部署门禁断言）。
     *
     * @return void；断言失败即有人改动了真实客户端 IP 的取值口径
     */
    @Test
    void forwardHeadersStrategyIsFramework() {
        assertThat(loadApplicationYaml().getProperty("server.forward-headers-strategy"))
                .isEqualTo("framework");
    }

    /**
     * 断言 {@code s2s.secrets.*} 九键逐一引用预期环境变量、且全部为无默认值硬占位。
     * 依据：编码规范 §3.3 凭证清单；安全 §4 key_version 列表结构；jwt-secret 为
     * [122] KTD10 新增（占位从八处加到九处）。
     * 变量名与仓库根 .env.example 逐一对应，任一侧改名都会打破本断言或 grep 核对。
     * 注意：占位「无默认值」指 yml 层不写兜底值；启动期硬守卫覆盖前七个硬依赖
     * （jwtSecret 叠加 ≥32 字节长度守卫），
     * SMS_KEY/AMAP_KEY 本条目为可选绑定（计划 OQ-3，评审 finding #1），其未注入时
     * 由 SecretsProperties 构造器归一为 null，不阻断 compose 整栈启动。
     *
     * @return void；断言失败即凭证占位变量名漂移或引入了默认值
     */
    @Test
    void secretsSectionReferencesExpectedEnvVarsWithoutDefaults() {
        Properties yaml = loadApplicationYaml();

        assertThat(yaml.getProperty("s2s.secrets.db-password")).isEqualTo("${SPRING_DATASOURCE_PASSWORD}");
        assertThat(yaml.getProperty("s2s.secrets.redis-password")).isEqualTo("${SPRING_DATA_REDIS_PASSWORD}");
        assertThat(yaml.getProperty("s2s.secrets.hmac-peppers-json")).isEqualTo("${HMAC_PEPPERS_JSON}");
        assertThat(yaml.getProperty("s2s.secrets.aead-master-keys-json")).isEqualTo("${AEAD_MASTER_KEYS_JSON}");
        assertThat(yaml.getProperty("s2s.secrets.oss-access-key-id")).isEqualTo("${OSS_ACCESS_KEY_ID}");
        assertThat(yaml.getProperty("s2s.secrets.oss-access-key-secret")).isEqualTo("${OSS_ACCESS_KEY_SECRET}");
        assertThat(yaml.getProperty("s2s.secrets.jwt-secret")).isEqualTo("${JWT_SECRET}");
        assertThat(yaml.getProperty("s2s.secrets.sms-key")).isEqualTo("${SMS_KEY}");
        assertThat(yaml.getProperty("s2s.secrets.amap-key")).isEqualTo("${AMAP_KEY}");
    }
}
