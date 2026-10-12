package com.s2s.server.notify;

/**
 * 推送下发结果（[B2-2]；供调用方与测试观察降级原因）。
 *
 * @param stationNotified 站内通知是否已写入（恒 {@code true}——站内是兜底，先写后发）
 * @param quotaAvailable  是否占到了当日推送配额（{@code false} = 超限或 Redis 不可用，
 *                        此时只留站内）
 * @param attempted       实际调用厂商发送器的设备数（无发送器 / 无通道的设备不计入）
 * @param accepted        厂商受理的设备数（{@code accepted <= attempted}）
 */
public record PushDispatchResult(boolean stationNotified, boolean quotaAvailable,
        int attempted, int accepted) {
}
