package com.s2s.server.common.moderation;

import org.springframework.stereotype.Component;

/**
 * 媒体审核桩实现（[123] U8；Batch1 占位）。
 *
 * <p>职责：Batch1 无 {@code post_media} 审核链路（post 域 {@code MediaService}
 * 未落地），本桩恒判「已过审」（{@link #checkApproved} 空实现）。post 域媒体
 * 审核落地后，以真实 {@link MediaAuditChecker} 实现替换本 Bean。</p>
 *
 * <p>为什么是桩：头像 media_id 是 {@code 40902} 的消费点，接口 + 桩保证
 * 「调用点稳定 + 测试可 mock」，避免 post 域落地时改 {@code UserService} 内部。</p>
 */
@Component
public class NoopMediaAuditChecker implements MediaAuditChecker {

    /**
     * 空实现：恒判已过审（Batch1 无审核链路）。
     *
     * @param mediaId 媒体 ID（本桩不校验，仅保持接口契约）
     */
    @Override
    public void checkApproved(String mediaId) {
        // TODO(post 域落地后)：接入真实 media 审核，未过审抛 40902
    }
}
