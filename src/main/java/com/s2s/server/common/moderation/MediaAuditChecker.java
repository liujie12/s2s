package com.s2s.server.common.moderation;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;

/**
 * 媒体审核接口（[123] U8；跨域媒体审核抽象）。
 *
 * <p>职责：校验媒体是否已通过审核（{@code audit_status=pass}），未过审抛
 * {@link BizException}({@code 40902})。消费方为 auth 域头像 media_id（U8）与
 * post 域发布 media 校验（后续条目），故抽象为 common 接口；实现归 post 域
 * {@code MediaService}（查 {@code post_media.audit_status}），Batch1 未落地，
 * 由桩实现承载（见 {@link NoopMediaAuditChecker}）。</p>
 *
 * <p>出处：详设 §5.1（头像 media_id 须 audit_status=pass）、§5.3.2（媒体校验）、
 * ErrorCode 40902。</p>
 */
public interface MediaAuditChecker {

    /**
     * 校验媒体是否已过审。
     *
     * @param mediaId 媒体 ID（已 commit 的 media_id）
     * @throws BizException 未过审（audit_status != pass）→ {@code 40902}
     */
    void checkApproved(String mediaId);
}
