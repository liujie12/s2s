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
 * <p>断言面：六个硬依赖凭证齐备时绑定成功；硬依赖缺键（null）、占位字面量未解析
 * （{@code "${VAR}"} 原样绑入——@ConfigurationProperties 非严格占位解析的真实行为，
 * U-5 N2 首跑实测复现）、空白串（compose 插值缺省落空串的 D8 叠加路径）三种
 * 「未真实注入」形态均被紧凑构造器守卫拒收，且报错点名环境变量名。
 * 短信/高德 Key 本条目为可选绑定（计划 OQ-3，评审 finding #1）：三种未注入形态
 * 归一为 null、真实值原样保留，保证 compose 模板不注入这两个变量时整栈可启动。
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
     * 场景二：硬依赖缺键（字段为 null）时绑定失败且报错点名环境变量。
     * 依据：record 构造绑定无隐式默认值，缺键即 null，被构造器守卫拒收。
     * （用 OSS_ACCESS_KEY_ID 硬依赖键；短信/高德 Key 已降级可选，见场景五。）
     *
     * @return void；断言失败即缺键路径存在「缺了也能跑」的隐式默认值
     */
    @Test
    void missingKeyFailsBindingWithEnvVarNamed() {
        Map<String, String> incomplete = new LinkedHashMap<>(FULL_PROPERTIES);
        incomplete.remove("s2s.secrets.oss-access-key-id");

        assertThatThrownBy(() -> bind(incomplete).get())
                .hasStackTraceContaining("OSS_ACCESS_KEY_ID");
    }

    /**
     * 场景三（生产关键）：硬依赖值是未解析占位字面量 {@code "${HMAC_PEPPERS_JSON}"}
     * 时绑定失败且点名变量。
     * 依据：@ConfigurationProperties 绑定走非严格占位解析，环境变量缺失时占位符【不抛异常】
     * 而是原样绑进字段（U-5 N2 首跑实测：缺 HMAC_PEPPERS_JSON 应用居然 Started）；
     * 这正是构造器守卫必须识别 "${...}" 整体形态的原因——本测试锁住该行为，防回归。
     *
     * @return void；断言失败即守卫对未解析占位字面量放行，快速失败形同虚设
     */
    @Test
    void unresolvedPlaceholderLiteralFailsBindingWithEnvVarNamed() {
        Map<String, String> unresolved = new LinkedHashMap<>(FULL_PROPERTIES);
        unresolved.put("s2s.secrets.hmac-peppers-json", "${HMAC_PEPPERS_JSON}");

        assertThatThrownBy(() -> bind(unresolved).get())
                .hasStackTraceContaining("HMAC_PEPPERS_JSON");
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

    /**
     * 场景五（评审 finding #1 / 计划 OQ-3）：短信/高德 Key 本条目为可选绑定。
     * 依据：Batch1 后端无短信/地图消费方，compose 叠加路径不注入 SMS_KEY/AMAP_KEY，
     * 三种「未真实注入」形态（缺键 null、未解析占位字面量、空白）必须归一为 null
     * 而非启动失败，保证按 deploy 模板起整栈可成功；真实注入值必须原样保留。
     *
     * @return void；断言失败即可选键要么误阻断启动、要么吞掉真实配置
     */
    @Test
    void optionalSmsAndAmapKeysNormalizeAbsentShapesToNullAndKeepRealValue() {
        // 缺键：compose 模板根本不注入这两个变量（finding #1 的部署路径）
        Map<String, String> withoutOptional = new LinkedHashMap<>(FULL_PROPERTIES);
        withoutOptional.remove("s2s.secrets.sms-key");
        withoutOptional.remove("s2s.secrets.amap-key");
        SecretsProperties absent = bind(withoutOptional).get();
        assertThat(absent.smsKey()).isNull();
        assertThat(absent.amapKey()).isNull();

        // 未解析占位字面量与夹带空白：同样归一为 null，不把 "${...}" 当假凭证放出
        Map<String, String> unresolvedOptional = new LinkedHashMap<>(FULL_PROPERTIES);
        unresolvedOptional.put("s2s.secrets.sms-key", "${SMS_KEY}");
        unresolvedOptional.put("s2s.secrets.amap-key", "   ");
        SecretsProperties normalized = bind(unresolvedOptional).get();
        assertThat(normalized.smsKey()).isNull();
        assertThat(normalized.amapKey()).isNull();

        // 真实注入原样保留（[123]/[126] 收紧前的本机直跑/已配置环境）
        SecretsProperties configured = bind(FULL_PROPERTIES).get();
        assertThat(configured.smsKey()).isEqualTo("fake-sms-key");
        assertThat(configured.amapKey()).isEqualTo("fake-amap-key");
    }
}
