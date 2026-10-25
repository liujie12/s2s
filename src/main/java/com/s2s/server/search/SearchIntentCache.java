package com.s2s.server.search;

import com.s2s.server.common.constants.NfrSearch;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.HexFormat;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * 语义解析结果缓存（文本 + 城市 + 提示词版本）。
 *
 * <p><b>为什么键里必须有城市、不能有坐标</b>：同一句话在不同城市指向不同小区，
 * 只按文本缓存会把 A 城市的结果返回给 B；而把精确坐标放进键，同一句话换个路口
 * 就不命中，缓存形同虚设。故缓存只放「语义槽位」，地点/小区由调用方每次按请求
 * 坐标重新解析。</p>
 *
 * <p><b>失败开放</b>：Redis 不可用时读返回 null、写静默丢弃，搜索退化为直接调 AI，
 * 不因缓存故障阻断主链路。</p>
 */
@Component
public class SearchIntentCache {

    /** 日志。 */
    private static final Logger LOG = LoggerFactory.getLogger(SearchIntentCache.class);

    private final StringRedisTemplate redisTemplate;

    /**
     * 构造缓存。
     *
     * @param redisTemplate Redis 字符串模板
     */
    public SearchIntentCache(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 读取缓存的 AI 原始输出。
     *
     * @param normalizedText 归一化文本
     * @param cityAdcode     城市 adcode（可空）
     * @return {@link String} AI 原始 JSON；未命中/Redis 异常返回 null
     */
    public String get(String normalizedText, String cityAdcode) {
        try {
            return redisTemplate.opsForValue().get(keyOf(normalizedText, cityAdcode));
        } catch (RuntimeException exception) {
            LOG.warn("语义解析缓存读取失败，按未命中处理：{}", exception.getClass().getSimpleName());
            return null;
        }
    }

    /**
     * 写入 AI 原始输出。
     *
     * @param normalizedText 归一化文本
     * @param cityAdcode     城市 adcode（可空）
     * @param rawAiOutput    AI 原始 JSON（非空）
     */
    public void put(String normalizedText, String cityAdcode, String rawAiOutput) {
        if (rawAiOutput == null || rawAiOutput.isBlank()) {
            return;
        }
        try {
            redisTemplate.opsForValue().set(keyOf(normalizedText, cityAdcode), rawAiOutput,
                    Duration.ofSeconds(NfrSearch.AI_PARSE_CACHE_TTL_SECONDS));
        } catch (RuntimeException exception) {
            LOG.warn("语义解析缓存写入失败，忽略：{}", exception.getClass().getSimpleName());
        }
    }

    /**
     * 拼装缓存键：前缀 + 提示词版本 + 城市 + 文本 SHA-256。
     *
     * @param normalizedText 归一化文本
     * @param cityAdcode     城市 adcode（可空）
     * @return {@link String} Redis 键
     */
    String keyOf(String normalizedText, String cityAdcode) {
        String city = cityAdcode == null || cityAdcode.isBlank() ? "-" : cityAdcode;
        return NfrSearch.AI_PARSE_CACHE_PREFIX + ":v" + NfrSearch.AI_PARSE_PROMPT_VERSION
                + ":" + city + ":" + sha256(normalizedText);
    }

    /**
     * 计算 SHA-256（十六进制）。
     *
     * @param value 原值
     * @return {@link String} 64 位十六进制摘要
     */
    private String sha256(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 不可用", exception);
        }
    }
}
