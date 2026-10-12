package com.s2s.server.notify;

import com.s2s.server.auth.PushPlatform;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.springframework.stereotype.Component;

/**
 * 推送发送器路由表（[B2-2]）。
 *
 * <p>按 {@link PushSender#platform()} 建索引；同一通道注册两个实现即**启动失败**
 * （{@code IllegalStateException}）——静默取最后一个会让「新实现没生效」表现为
 * 随机行为，排查成本远高于启动即报错。</p>
 *
 * <p><b>阶段 1 路由表为空</b>（各厂商凭据未办，见 {@link PushSender} 类注释）：
 * {@link #forPlatform} 恒返回 {@code Optional.empty()}，调用方据此走站内兜底降级。</p>
 */
@Component
public class PushSenderRegistry {

    /** 通道 → 发送器。 */
    private final Map<PushPlatform, PushSender> byPlatform = new EnumMap<>(PushPlatform.class);

    /**
     * 构造路由表。
     *
     * @param senders 容器内全部 {@link PushSender} 实现（阶段 1 为空列表）
     * @throws IllegalStateException 同一通道重复注册
     */
    public PushSenderRegistry(List<PushSender> senders) {
        for (PushSender sender : senders) {
            PushSender previous = byPlatform.put(sender.platform(), sender);
            if (previous != null) {
                throw new IllegalStateException(
                        "推送通道 " + sender.platform().wire() + " 重复注册发送器："
                                + previous.getClass().getName() + " / " + sender.getClass().getName());
            }
        }
    }

    /**
     * 取某通道的发送器。
     *
     * @param platform 推送通道
     * @return {@link Optional} 命中的发送器；未注册（含阶段 1 全空）返回空
     */
    public Optional<PushSender> forPlatform(PushPlatform platform) {
        return Optional.ofNullable(byPlatform.get(platform));
    }
}
