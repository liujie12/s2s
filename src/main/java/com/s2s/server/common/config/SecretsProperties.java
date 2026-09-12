package com.s2s.server.common.config;

import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * 六类凭证的绑定载体（编码规范 §3.3「六类凭证不入仓库、不入镜像；缺变量启动快速失败」；安全 §4）。
 *
 * <p>职责：把 application.yml 中 {@code s2s.secrets.*} 的无默认值硬占位绑定为强类型对象，
 * 任一环境变量缺失/为空白/占位未解析即启动失败，报错直接点名变量名。
 *
 * <p>快速失败机制（U-5 实测踩坑后定稿，勿改回纯占位依赖）：
 * {@code @ConfigurationProperties} 绑定走的是 {@code PropertySourcesPlaceholdersResolver}
 * 非严格模式（{@code ignoreUnresolvablePlaceholders=true}），环境变量缺失时占位符
 * 【不会】抛异常，而是把字面量 {@code "${HMAC_PEPPERS_JSON}"} 原样绑进字段——非空白、
 * 能骗过 {@code @NotBlank}，应用带病启动（U-5 N2 首跑实测复现：缺 HMAC_PEPPERS_JSON
 * 应用居然 Started）。因此真正的快速失败闸门是本 record 紧凑构造器里的
 * {@link #requireResolved(String, String)} 显式守卫：值为 null（键缺失）、空白
 * （compose 插值缺省落空串，D8 叠加路径）或整体形如 {@code "${...}"}（占位未解析）
 * 一律抛 {@link IllegalArgumentException} 并点名环境变量名，绑定失败 = 启动失败。
 * 严格解析（缺失即抛 {@code Could not resolve placeholder}）只存在于
 * {@code @Value} 硬注入路径（如 config/FlywayTrackConfig），{@code @ConfigurationProperties}
 * 路径不可依赖。
 *
 * <p>凭证清单：DB 口令、Redis 口令、HMAC pepper 列表、AEAD 主密钥列表、OSS AK/SK
 * 为本条目启动硬依赖（缺失即快速失败）；短信/高德 Key 按计划 OQ-3 在本条目为
 * <b>可选绑定</b>——Batch1 后端无短信/地图消费方，compose 叠加路径也不注入这两个变量，
 * 若做硬守卫会让按部署模板起整栈必然启动失败（评审 finding #1）。收紧时点：
 * SMS_KEY 随条目 [123]（短信登录验证码渠道）、AMAP_KEY 随条目 [126]（逆地理/POI 服务）
 * 落地时改回 {@code @NotBlank} + {@link #requireResolved(String, String)} 硬守卫，
 * 并同步在 deploy/env 三份模板补占位。两个密钥列表按 {@code key_version} 列表结构
 * 承载 JSON 串（安全 §4：轮换时新旧版本并存于列表）。
 *
 * <p>设计取舍：
 * <ul>
 *   <li>用 record 构造绑定（Boot 3 原生支持，无需 @ConstructorBinding）：凭证对象不可变，
 *       杜绝运行期被改写；</li>
 *   <li>字段一律 String：Batch1 只做「绑定 + 非空/已解析校验」，JSON 内容解析
 *       随条目[124] crypto 组件落地——此处不提前设计解析口径；</li>
 *   <li>{@link Validated} + {@link NotBlank} 保留为声明式兜底（任务口径），
 *       权威判定在构造器守卫（先执行、报错含变量名）。</li>
 * </ul>
 *
 * <p>注册方式：由 {@code S2sServerApplication} 上的 {@code @ConfigurationPropertiesScan}
 * 扫描注册（理由见启动类注释）。
 *
 * @param dbPassword         业务库口令（与 spring.datasource.password 同一变量二次引用，双保险）
 * @param redisPassword      Redis 口令（与 spring.data.redis.password 同一变量二次引用，双保险）
 * @param hmacPeppersJson    HMAC pepper 列表 JSON（盲索引 {@code xxx_hash} 的 HMAC-SHA256 密钥，
 *                           按 key_version 列表结构，安全 §4）
 * @param aeadMasterKeysJson AEAD 主密钥列表 JSON（AES-GCM-256 原语密钥，
 *                           按 key_version 列表结构，安全 §4）
 * @param ossAccessKeyId     阿里云 OSS AccessKey ID（媒体对象存储凭证）
 * @param ossAccessKeySecret 阿里云 OSS AccessKey Secret（媒体对象存储凭证）
 * @param smsKey             短信服务 Key（登录验证码渠道凭证）；本条目可选绑定（OQ-3），
 *                           未注入/占位未解析/空白统一归一为 null，[123] 落地时收紧为硬守卫
 * @param amapKey            高德地图 Key（逆地理/POI 服务凭证）；本条目可选绑定（OQ-3），
 *                           未注入/占位未解析/空白统一归一为 null，[126] 落地时收紧为硬守卫
 */
@Validated
@ConfigurationProperties(prefix = "s2s.secrets")
public record SecretsProperties(
        @NotBlank String dbPassword,
        @NotBlank String redisPassword,
        @NotBlank String hmacPeppersJson,
        @NotBlank String aeadMasterKeysJson,
        @NotBlank String ossAccessKeyId,
        @NotBlank String ossAccessKeySecret,
        String smsKey,
        String amapKey) {

    /**
     * 紧凑构造器：六个硬依赖凭证逐字段执行 {@link #requireResolved(String, String)} 守卫，
     * 任一未真实注入即让绑定失败（启动快速失败，编码规范 §3.3）；短信/高德 Key 走
     * {@link #normalizeOptional(String)} 归一为可选绑定（计划 OQ-3，评审 finding #1）。
     */
    public SecretsProperties {
        requireResolved(dbPassword, "SPRING_DATASOURCE_PASSWORD");
        requireResolved(redisPassword, "SPRING_DATA_REDIS_PASSWORD");
        requireResolved(hmacPeppersJson, "HMAC_PEPPERS_JSON");
        requireResolved(aeadMasterKeysJson, "AEAD_MASTER_KEYS_JSON");
        requireResolved(ossAccessKeyId, "OSS_ACCESS_KEY_ID");
        requireResolved(ossAccessKeySecret, "OSS_ACCESS_KEY_SECRET");
        smsKey = normalizeOptional(smsKey);
        amapKey = normalizeOptional(amapKey);
    }

    /**
     * 凭证已解析性守卫：三种「未真实注入」形态一律拒绝并点名环境变量。
     *
     * @param value  绑定到的字段值（可能为 null、空白或未解析的占位字面量）
     * @param envVar 该字段对应的环境变量名（用于报错定位）
     * @throws IllegalArgumentException 值为 null、空白、或整体形如 {@code "${...}"} 时抛出；
     *         异常信息含环境变量名，随绑定失败终止启动
     */
    private static void requireResolved(String value, String envVar) {
        if (value == null || value.isBlank() || (value.startsWith("${") && value.endsWith("}"))) {
            throw new IllegalArgumentException(
                    "凭证未注入或占位未解析，启动快速失败（编码规范 §3.3）：请检查环境变量 " + envVar);
        }
    }

    /**
     * 可选凭证归一：本条目 Batch1 无消费方的短信/高德 Key（计划 OQ-3），三种「未真实注入」
     * 形态——null（键缺失）、空白（compose 插值缺省落空串）、整体形如 {@code "${...}"}
     * （非严格占位解析把字面量原样绑入）——统一归一为 {@code null}，消费方据此判定「未配置」；
     * 真实注入则原样保留。条目 [123]/[126] 落地消费方时，本方法应换回
     * {@link #requireResolved(String, String)} 硬守卫并恢复 {@code @NotBlank}。
     *
     * @param value 绑定到的可选字段值（可能为 null、空白、未解析占位字面量或真实 Key）
     * @return 真实注入时原值；三种未注入形态归一为 {@code null}
     */
    private static String normalizeOptional(String value) {
        if (value == null || value.isBlank() || (value.startsWith("${") && value.endsWith("}"))) {
            return null;
        }
        return value;
    }
}
