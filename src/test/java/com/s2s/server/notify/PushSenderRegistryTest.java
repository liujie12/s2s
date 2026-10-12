package com.s2s.server.notify;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.PushPlatform;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * {@link PushSenderRegistry} 路由表测试（[B2-2]）。
 *
 * <p>守的是什么：路由表的两种失效都很静默 —— 同通道注册两个实现时若「后者胜」，
 * 表现为「新实现没生效」的随机行为；而查不到发送器时必须返回空（走站内兜底），
 * 若抛异常会让一条推送配置缺失升级成下发链路整体失败。</p>
 */
class PushSenderRegistryTest {

    /**
     * 阶段 1 实况：无任何实现 → 查任何通道都返回空（据此走站内兜底降级）。
     *
     * @return void
     */
    @Test
    void emptyRegistryReturnsEmptyForAnyPlatform() {
        PushSenderRegistry registry = new PushSenderRegistry(List.of());

        assertThat(registry.forPlatform(PushPlatform.MI)).isEmpty();
        assertThat(registry.forPlatform(PushPlatform.APNS)).isEmpty();
    }

    /**
     * 已注册通道：按通道键命中对应实现。
     *
     * @return void
     */
    @Test
    void registryRoutesByPlatform() {
        PushSender xiaomi = mock(PushSender.class);
        when(xiaomi.platform()).thenReturn(PushPlatform.MI);
        PushSenderRegistry registry = new PushSenderRegistry(List.of(xiaomi));

        assertThat(registry.forPlatform(PushPlatform.MI)).contains(xiaomi);
        assertThat(registry.forPlatform(PushPlatform.APNS)).isEmpty();
    }

    /**
     * 同通道重复注册：构造即抛（启动失败优于运行时随机行为）。
     *
     * @return void
     */
    @Test
    void duplicatePlatformFailsFast() {
        PushSender first = mock(PushSender.class);
        PushSender second = mock(PushSender.class);
        when(first.platform()).thenReturn(PushPlatform.MI);
        when(second.platform()).thenReturn(PushPlatform.MI);

        assertThatThrownBy(() -> new PushSenderRegistry(List.of(first, second)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("mi");
    }
}
