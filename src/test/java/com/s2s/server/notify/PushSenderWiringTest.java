package com.s2s.server.notify;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.web.client.RestClient;

/**
 * 推送发送器的 Spring 装配回归测试（2026-10-21 生产启动事故后补）。
 *
 * <p><b>为什么需要本类</b>：容器内同时存在两个同类型 {@link RestClient} bean
 * （{@code aiRestClient} 与 {@code pushRestClient}）。{@link XiaomiPushSender} /
 * {@link HuaweiPushSender} 曾按类型注入，生产开启 {@code s2s.push.xiaomi.enabled=true} 后
 * 启动即 {@code UnsatisfiedDependencyException}（APPLICATION FAILED TO START）；而既有单测
 * 全部直接 {@code new} 发送器，绕过了 Spring 装配，546 个用例全绿却漏检。</p>
 *
 * <p>本类用 {@link ApplicationContextRunner} 复现「同类型多 bean」最小上下文，断言两个
 * 发送器仍可被创建 —— 一旦有人删掉构造器上的 {@code @Qualifier}，此处立即失败。</p>
 */
class PushSenderWiringTest {

    /** 打桩 AppSecret（假值，仅满足非空校验）。 */
    private static final String FAKE_SECRET = "wiring-test-secret";

    /** 打桩包名（须与小米后台一致的真实格式，仅用于装配）。 */
    private static final String PACKAGE_NAME = "com.s2s.zhaoyazhao.dev";

    /** 模拟生产容器：两个同类型 RestClient bean + JSON 序列化器。 */
    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withBean("aiRestClient", RestClient.class, RestClient::create)
            .withBean("pushRestClient", RestClient.class, RestClient::create)
            .withBean(ObjectMapper.class);

    /**
     * 小米发送器在「同类型多 bean」环境下可装配。
     *
     * <p>复现生产故障形态：缺少 {@code @Qualifier("pushRestClient")} 时本用例失败。</p>
     */
    @Test
    void xiaomiSenderWiresWithTwoRestClientBeans() {
        runner.withBean(XiaomiPushSender.class)
                .withPropertyValues(
                        "s2s.push.xiaomi.enabled=true",
                        "s2s.push.xiaomi.app-secret=" + FAKE_SECRET,
                        "s2s.push.xiaomi.package-name=" + PACKAGE_NAME)
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context).hasSingleBean(XiaomiPushSender.class);
                });
    }

    /**
     * 华为发送器在「同类型多 bean」环境下可装配。
     *
     * <p>与小米同源缺陷，一并守住。</p>
     */
    @Test
    void huaweiSenderWiresWithTwoRestClientBeans() {
        runner.withBean(HuaweiPushSender.class)
                .withPropertyValues(
                        "s2s.push.huawei.enabled=true",
                        "s2s.push.huawei.app-id=100000001",
                        "s2s.push.huawei.app-secret=" + FAKE_SECRET)
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context).hasSingleBean(HuaweiPushSender.class);
                });
    }
}
