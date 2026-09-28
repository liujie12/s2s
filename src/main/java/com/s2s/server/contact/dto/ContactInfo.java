package com.s2s.server.contact.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 完整联系方式（[128]；对应 openapi {@code GET /posts/{post_id}/contact} 响应 {@code data}）。
 *
 * <p><b>本 DTO 是全系统唯一返回完整联系方式的载体</b>（PRD §14.3、安全 §3）。
 * 其他任何接口（详情、列表、卡片）只回 {@code contact_mask} 脱敏值，
 * 且详情接口的 {@code contact_mask} 在 Batch1 恒为 {@code null}
 * （口径源：{@code PostDetail} 类注释；脱敏值属联系中转页职责）。</p>
 *
 * <p><b>{@code remainingToday} 的字段纪律</b>（openapi {@code ContactInfo.remaining_today}
 * 原文）：它<b>只反映账号维度</b>一个维度的剩余量，而服务端限频有四个维度
 * （账号 / 设备 / IP / 熔断）。因此「显示剩 3 次 → 第 2 次就被拒」是正常且必然发生的
 * 场景，客户端文案必须写「今日剩余 N 次（以实际请求结果为准）」而<b>不得</b>写成
 * 「今日还可查看 N 次」，且收到 {@code 42902} 后须立即把本地剩余刷 0。</p>
 *
 * @param contactType    联系方式类型（{@code phone} / {@code wechat}）
 * @param contactValue   解密后的完整联系方式（服务端唯一出口，客户端用完即弃）
 * @param remainingToday 今日剩余可查看次数（仅账号维度，非承诺值）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ContactInfo(
        String contactType,
        String contactValue,
        int remainingToday) {
}
