package com.s2s.server.common.config;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.crypto.MasterKey;
import com.s2s.server.common.crypto.Pepper;
import java.util.List;
import java.util.Map;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 加解密组件 Spring 装配（[123] U1；详设 §4.1「三列范式」）。
 *
 * <p>职责：把 {@link SecretsProperties} 中承载的 JSON 字符串解析为
 * {@code List<MasterKey>} 与 {@code List<Pepper>}，注册为 Spring Bean 供 {@code CryptoFacade} 等消费方注入。</p>
 *
 * <p>解析时机：应用启动期（{@code @Bean} 方法在容器初始化时执行一次），运行期不重复解析。
 * 解析失败 = 启动失败（JSON 格式错误 / 密钥长度非法 / 版本号缺失），
 * 与既有凭证守卫同构的快速失败——密钥不可用的应用必须起不来，而不是运行期才暴露。</p>
 *
 * <p>出处：详设 §4.1（三列范式：{@code xxx_hash} + {@code xxx_enc} + {@code key_version}）；
 * 安全 §4（密钥轮换）；编码规范 §3.3（六类凭证）。</p>
 */
@Configuration
public class CryptoConfig {

    /** JSON 字段名：密钥版本号（对应数据库 {@code key_version TINYINT} 列）。 */
    private static final String FIELD_VERSION = "version";

    /** JSON 字段名：密钥原始值（hex 或 base64 编码的字节串）。 */
    private static final String FIELD_KEY = "key";

    /** Jackson 对象映射器（Spring Boot 自动装配的单例）。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造加解密配置：注入 Spring Boot 自动装配的 {@link ObjectMapper}。
     *
     * @param objectMapper Jackson 对象映射器（Spring Boot 自动装配）
     */
    public CryptoConfig(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    /**
     * 解析 HMAC pepper 列表 JSON，注册为 Spring Bean。
     *
     * <p>JSON 形态：{@code [{"version":1,"key":"<hex 或 base64>"}]}。
     * 解析失败（格式错误 / 版本号缺失 / 密钥非法）→ 启动失败。</p>
     *
     * @param secrets 六类凭证绑定载体（注入 {@link SecretsProperties}）
     * @return HMAC pepper 列表
     * @throws IllegalStateException 解析失败时抛出
     */
    @Bean
    public List<Pepper> hmacPeppers(SecretsProperties secrets) {
        List<Map<String, Object>> items = parseItems(secrets.hmacPeppersJson(), "HMAC pepper");
        return items.stream()
                .map(item -> Pepper.of(requireVersion(item, "HMAC pepper"), requireKey(item, "HMAC pepper")))
                .toList();
    }

    /**
     * 解析 AEAD 主密钥列表 JSON，注册为 Spring Bean。
     *
     * <p>JSON 形态：{@code [{"version":1,"key":"<hex 或 base64>"}]}。
     * 解析失败（格式错误 / 版本号缺失 / 密钥长度非 32 字节）→ 启动失败。</p>
     *
     * @param secrets 六类凭证绑定载体（注入 {@link SecretsProperties}）
     * @return AEAD 主密钥列表
     * @throws IllegalStateException 解析失败时抛出
     */
    @Bean
    public List<MasterKey> aeadMasterKeys(SecretsProperties secrets) {
        List<Map<String, Object>> items = parseItems(secrets.aeadMasterKeysJson(), "AEAD 主密钥");
        return items.stream()
                .map(item -> MasterKey.of(requireVersion(item, "AEAD 主密钥"), requireKey(item, "AEAD 主密钥")))
                .toList();
    }

    /**
     * 解析密钥列表 JSON 为原始条目映射（含格式与空列表校验）。
     *
     * @param json    JSON 字符串
     * @param subject 报错时的主语（如「HMAC pepper」），用于把错误定位到具体凭证
     * @return 条目映射列表（非空）
     * @throws IllegalStateException JSON 解析失败或列表为空时抛出
     */
    private List<Map<String, Object>> parseItems(String json, String subject) {
        List<Map<String, Object>> items;
        try {
            items = objectMapper.readValue(json, new TypeReference<List<Map<String, Object>>>() {});
        } catch (com.fasterxml.jackson.core.JsonProcessingException exception) {
            throw new IllegalStateException(subject + "列表 JSON 解析失败（格式错误）", exception);
        }
        if (items == null || items.isEmpty()) {
            throw new IllegalStateException(subject + "列表不可为空（至少需要一个密钥版本）");
        }
        return items;
    }

    /**
     * 从条目中取版本号并校验存在性。
     *
     * <p>为什么必须显式校验：版本号决定密文/索引归属哪一版密钥，
     * 缺失会让解密取错密钥（表现为「解密失败」而非「配置缺失」，排查成本高），
     * 故在启动期就点名报错。</p>
     *
     * @param item    条目映射
     * @param subject 报错主语
     * @return 版本号（{@code key_version} 列值）
     * @throws IllegalStateException 版本号缺失或非整数时抛出
     */
    private int requireVersion(Map<String, Object> item, String subject) {
        Object raw = item.get(FIELD_VERSION);
        if (raw instanceof Number number) {
            return number.intValue();
        }
        throw new IllegalStateException(
                subject + "条目的 " + FIELD_VERSION + " 字段缺失或非整数：" + raw);
    }

    /**
     * 从条目中取密钥值并校验存在性。
     *
     * @param item    条目映射
     * @param subject 报错主语
     * @return 密钥字符串（hex 或 base64）
     * @throws IllegalStateException 密钥缺失或为空白时抛出
     */
    private String requireKey(Map<String, Object> item, String subject) {
        Object raw = item.get(FIELD_KEY);
        if (raw instanceof String key && !key.isBlank()) {
            return key;
        }
        throw new IllegalStateException(subject + "条目的 " + FIELD_KEY + " 字段缺失或为空白");
    }
}
