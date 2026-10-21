package com.s2s.server.config;

import com.s2s.server.common.constants.NfrPush;
import java.time.Duration;
import org.springframework.boot.http.client.ClientHttpRequestFactoryBuilder;
import org.springframework.boot.http.client.ClientHttpRequestFactorySettings;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.ClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * 推送域厂商 HTTP 客户端装配（B2-2 阶段 2）。
 *
 * <p><b>为什么单独出一个 {@link RestClient} bean</b>：与 {@link AiClientConfig} 同因 ——
 * 超时必须在构建前定死在 builder 上；测试要用 {@code MockRestServiceServer.bindTo} 换成
 * 打桩工厂，若 Sender 自己在构造器里再设 requestFactory 会把桩覆盖掉。</p>
 *
 * <p><b>不设 baseUrl</b>：华为与小米是两家不同域名，且华为的路径里含 AppID（运行时才知）。
 * 故由各 Sender 传绝对 URL，本 bean 只统一超时与客户端选型。</p>
 */
@Configuration
public class PushClientConfig {

    /**
     * 推送厂商通用 HTTP 客户端（连接/读取超时取 {@link NfrPush#UPSTREAM_TIMEOUT_SECONDS}）。
     *
     * @param builder Spring Boot 自动装配的 RestClient 构建器
     * @return {@link RestClient} 仅带超时的客户端，URL 由调用方给出
     */
    @Bean
    RestClient pushRestClient(RestClient.Builder builder) {
        Duration timeout = Duration.ofSeconds(NfrPush.UPSTREAM_TIMEOUT_SECONDS);
        ClientHttpRequestFactory requestFactory = ClientHttpRequestFactoryBuilder.detect()
                .build(ClientHttpRequestFactorySettings.defaults()
                        .withConnectTimeout(timeout)
                        .withReadTimeout(timeout));
        return builder.requestFactory(requestFactory).build();
    }
}
