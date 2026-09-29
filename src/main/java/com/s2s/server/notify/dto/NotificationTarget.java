package com.s2s.server.notify.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 通知的跳转目标（openapi {@code Notification.target}；PRD §8.3.3「点击通知 → 跳对应详情」）。
 *
 * @param kind   目标类型（{@code post} 跳发布详情 / {@code cert} 跳信任与认证 / {@code none} 无跳转）
 * @param postId 目标帖子 ID；{@code kind != post} 时恒 {@code null}
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record NotificationTarget(String kind, Long postId) {

    /** 无跳转目标。 */
    public static final NotificationTarget NONE = new NotificationTarget("none", null);

    /** 跳信任与认证页。 */
    public static final NotificationTarget CERT = new NotificationTarget("cert", null);

    /**
     * 构造「跳发布详情」目标。
     *
     * @param postId 目标帖子 ID（非 null）
     * @return {@link NotificationTarget} {@code kind=post}
     */
    public static NotificationTarget post(Long postId) {
        return new NotificationTarget("post", postId);
    }
}
