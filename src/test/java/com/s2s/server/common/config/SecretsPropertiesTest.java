package com.s2s.server.common.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.BindResult;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.MapConfigurationPropertySource;

/**
 * {@link SecretsProperties} 绑定与守卫守门测试（U-5；编码规范 §3.3「缺变量启动快速失败」）。
 *
 * <p>选纯单测路径（不起 Spring 上下文）：用 {@link Binder} 直接对
 * {@link MapConfigurationPropertySource} 绑定，既不需要环境变量也不触达数据库，
 * 与现有 10 个纯单测同范式（互不干扰）。
 *
 * <p>四个断言面：六类凭证八字段齐备时绑定成功；缺键（null）、占位字面量未解析
 * （{@code "${VAR}"} 原样绑入——@ConfigurationProperties 非严格占位解析的真实行为，
 * U-5 N2 首跑实测复现）、空白串（compose 插值缺省落空串的 D8 叠加路径）三种
 * 「未真实注入」形态均被紧凑构造器守卫拒收，且报错点名环境变量名。
 */
class SecretsPropertiesTest {

    /** 六类凭证的八个绑定键与取值（假值，仅验证绑定通路）。 */
    private static final Map<String, String> FULL_PROPERTIES = fullProperties();

    /**
     * 构造全量假值属性源：八个键逐一对应编码规范 §3.3 六类凭证。
     *
     * @return 键为 s2s.secrets.*  relaxed 绑定名、值为假值的属性 Map
     */
    private static Map<String, String> fullProperties() {
        Map<String, String> properties = new LinkedHashMap<>();
        properties.put("s2s.secrets.db-password", "fake-db-password");
        properties.put("s2s.secrets.redis-password", "fake-redis-password");
        properties.put("s2s.secrets.hmac-peppers-json", "[{\"id\":\"p1\",\"key\":\"fake\"}]");
        properties.put("s2s.secrets.aead-master-keys-json", "[{\"id\":\"k1\",\"key\":\"fake\"}]");
        properties.put("s2s.secrets.oss-access-key-id", "fake-oss-ak");
        properties.put("s2s.secrets.oss-access-key-secret", "fake-oss-sk");
        properties.put("s2s.secrets.sms-key", "fake-sms-key");
        properties.put("s2s.secrets.amap-key", "fake-amap-key");
        return properties;
    }

    /**
     * 对给定属性源执行绑定（绑定即触发紧凑构造器守卫，无需再等 Bean Validation）。
     *
     * @param properties 属性 Map（键为 s2s.secrets.* 形式）
     * @return 绑定结果；守卫抛出的异常经 Binder 包装向上传播
     */
    private static BindResult<SecretsProperties> bind(
            Map<String, String> properties) {
        return new Binder(new MapConfigurationPropertySource(properties))
                .bind("s2s.secrets", Bindable.of(SecretsProperties.class));
    }

    /**
     * 场景一：八键齐备时构造绑定成功且逐字段取值一致。
     * 依据：编码规范 §3.3 六类凭证（DB/Redis 口令、HMAC pepper 列表、AEAD 主密钥列表、
     * OSS AK/SK、短信/高德 Key）缺一不可的反面——齐备必须能绑。
     *
     * @return void；断言失败即 record 构造绑定或 relaxed 命名失配
     */
    @Test
    void bindsAllEightFieldsWhenComplete() {
        SecretsProperties secrets = bind(FULL_PROPERTIES).get();

        assertThat(secrets.dbPassword()).isEqualTo("fake-db-password");
        assertThat(secrets.redisPassword()).isEqualTo("fake-redis-password");
        assertThat(secrets.hmacPeppersJson()).isEqualTo("[{\"id\":\"p1\",\"key\":\"fake\"}]");
        assertThat(secrets.aeadMasterKeysJson()).isEqualTo("[{\"id\":\"k1\",\"key\":\"fake\"}]");
        assertThat(secrets.ossAccessKeyId()).isEqualTo("fake-oss-ak");
        assertThat(secrets.ossAccessKeySecret()).isEqualTo("fake-oss-sk");
        assertThat(secrets.smsKey()).isEqualTo("fake-sms-key");
        assertThat(secrets.amapKey()).isEqualTo("fake-amap-key");
    }

    /**
     * 场景二：缺键（字段为 null）时绑定失败且报错点名环境变量。
     * 依据：record 构造绑定无隐式默认值，缺键即 null，被构造器守卫拒收。
     *
     * @return void；断言失败即缺键路径存在「缺了也能跑」的隐式默认值
     */
    @Test
    void missingKeyFailsBindingWithEnvVarNamed() {
        Map<String, String> incomplete = new LinkedHashMap<>(FULL_PROPERTIES);
        incomplete.remove("s2s.secrets.amap-key");

        assertThatThrownBy(() -> bind(incomplete).get())
                .hasStackTraceContaining("AMAP_KEY");
    }

    /**
     * 场景三（生产关键）：值是未解析占位字面量 {@code "${AMAP_KEY}"} 时绑定失败且点名变量。
     * 依据：@ConfigurationProperties 绑定走非严格占位解析，环境变量缺失时占位符【不抛异常】
     * 而是原样绑进字段（U-5 N2 首跑实测：缺 HMAC_PEPPERS_JSON 应用居然 Started）；
     * 这正是构造器守卫必须识别 "${...}" 整体形态的原因——本测试锁住该行为，防回归。
     *
     * @return void；断言失败即守卫对未解析占位字面量放行，快速失败形同虚设
     */
    @Test
    void unresolvedPlaceholderLiteralFailsBindingWithEnvVarNamed() {
        Map<String, String> unresolved = new LinkedHashMap<>(FULL_PROPERTIES);
        unresolved.put("s2s.secrets.amap-key", "${AMAP_KEY}");

        assertThatThrownBy(() -> bind(unresolved).get())
                .hasStackTraceContaining("AMAP_KEY");
    }

    /**
     * 场景四：变量被注入为空白串时绑定失败且点名变量。
     * 对应 compose 插值缺省落成空串的场景（D8 叠加路径）：光「变量存在」不算数，
     * 空白等同缺失，必须启动失败。
     *
     * @return void；断言失败即空白注入路径被放行
     */
    @Test
    void blankValueFailsBindingWithEnvVarNamed() {
        Map<String, String> blanked = new LinkedHashMap<>(FULL_PROPERTIES);
        blanked.put("s2s.secrets.hmac-peppers-json", "  ");

        assertThatThrownBy(() -> bind(blanked).get())
                .hasStackTraceContaining("HMAC_PEPPERS_JSON");
    }
}
