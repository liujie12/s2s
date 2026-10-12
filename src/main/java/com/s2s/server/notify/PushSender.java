package com.s2s.server.notify;

import com.s2s.server.auth.PushPlatform;

/**
 * 推送发送器（[B2-2]；PRD §6.14 推送通道）。
 *
 * <p><b>一个通道一个实现</b>：APNs / 华为 / 小米 / OPPO / vivo / 荣耀 各一家厂商协议，
 * 由各实现自行处理签名、端点与错误码。选路由 {@link PushSenderRegistry} 承担。</p>
 *
 * <p><b>阶段 1 无任何实现</b>（凭据未办，2026-10-12 裁定），故生产环境
 * {@link PushSenderRegistry} 的路由表为空 —— 下发路径会走「无发送器 → 跳过并记 WARN」
 * 的降级分支，站内通知照常写入。这**不是空壳实现**：接口与路由是真实能力，
 * 只是真实通道实现待凭据；刻意不提供「记日志的假发送器」，以免把「已实现」的
 * 假象留在代码里（同 {@code DevOssClient} 被否决的取向）。</p>
 */
public interface PushSender {

    /**
     * 本发送器负责的推送通道（注册表中按此键选路，同通道重复注册即启动失败）。
     *
     * @return {@link PushPlatform} 通道
     */
    PushPlatform platform();

    /**
     * 向单台设备下发一条通知形态推送。
     *
     * <p>实现方需自行容错：token 失效（厂商返回「无效 token」）时**不应抛异常中断
     * 同批其他设备**，而应记日志并返回 {@code false}；失效 token 的清理由
     * {@code device.push_token} 的运维清理承担（本轮不做自动清理）。</p>
     *
     * @param token   目标设备推送 token（非 null，调用方已过滤空 token）
     * @param message 推送载荷
     * @return boolean {@code true} 厂商已受理（不代表已送达）；{@code false} 未受理
     */
    boolean send(String token, PushMessage message);
}
