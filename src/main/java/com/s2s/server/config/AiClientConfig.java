package com.s2s.server.config;

import com.s2s.server.common.constants.NfrAi;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.http.client.ClientHttpRequestFactoryBuilder;
import org.springframework.boot.http.client.ClientHttpRequestFactorySettings;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.ClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * AI 域上游 HTTP 客户端装配（B2-4 阶段①，通义千问/阿里云百炼 OpenAI 兼容）。
 *
 * <p><b>为什么单独出一个 {@link RestClient} bean 而不在 {@code QwenAiProvider} 内自建</b>：
 * 请求工厂（含超时）必须在 <b>构建前</b> 定死在 builder 上，而测试要用
 * {@code MockRestServiceServer.bindTo(RestClient.Builder)} 换成打桩工厂——若 provider 自己
 * 在构造器里再 {@code requestFactory(...)}，会把桩工厂覆盖掉（顺序依赖、易碎）。故此处把
 * 「带 baseUrl + 超时的真客户端」装配成 bean，provider 只消费成品，测试另行构造打桩客户端。</p>
 *
 * <p><b>超时单源</b>：连接/读取超时一律取 {@link NfrAi#UPSTREAM_TIMEOUT_SECONDS}（禁写死数字），
 * 与 {@code AiParseService} 的失败口径一致——超时即抛异常 → 调用方映射 {@code 50301}。</p>
 *
 * <p><b>注</b>：{@code s2s.ai.endpoint} 的默认值（百炼 OpenAI 兼容 base URL）定义在
 * {@code application.yml}，本类不重复一份。</p>
 */
@Configuration
public class AiClientConfig {

    /**
     * 通义千问（百炼 OpenAI 兼容）专用 HTTP 客户端。
     *
     * @param builder  Spring Boot 自动装配的 RestClient 构建器（沿用其客户端选型与全局定制）
     * @param endpoint 上游 base URL（{@code s2s.ai.endpoint}，如
     *                 {@code https://dashscope.aliyuncs.com/compatible-mode/v1}）
     * @return {@link RestClient} 已带 baseUrl 与连接/读取超时的客户端
     */
    @Bean
    RestClient aiRestClient(RestClient.Builder builder,
            @Value("${s2s.ai.endpoint}") String endpoint) {
        Duration timeout = Duration.ofSeconds(NfrAi.UPSTREAM_TIMEOUT_SECONDS);
        ClientHttpRequestFactory requestFactory = ClientHttpRequestFactoryBuilder.detect()
                .build(ClientHttpRequestFactorySettings.defaults()
                        .withConnectTimeout(timeout)
                        .withReadTimeout(timeout));
        return builder.baseUrl(endpoint).requestFactory(requestFactory).build();
    }
}
