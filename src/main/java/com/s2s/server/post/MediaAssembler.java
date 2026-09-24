package com.s2s.server.post;

import com.s2s.server.post.dto.MediaItem;
import com.s2s.server.post.entity.PostMediaEntity;
import org.springframework.stereotype.Component;

/**
 * 媒体视图组装（[125]；R2 硬规则「视角分流，禁在 controller 判视角」）。
 *
 * <p>职责：把 {@link PostMediaEntity} 投影为 {@link MediaItem}，承载
 * {@code audit_status != pass} 不出现在非本人可见响应的视角分流。视角判定集中在
 * 本类，一处漏判等于把未过审图片下发他人。</p>
 */
@Component
public class MediaAssembler {

    private final OssClient ossClient;

    /**
     * 构造媒体组装器。
     *
     * @param ossClient OSS 客户端（签名访问 URL）
     */
    public MediaAssembler(OssClient ossClient) {
        this.ossClient = ossClient;
    }

    /**
     * 把媒体实体投影为媒体项 DTO（含视角分流）。
     *
     * <p>他人视角（{@code isOwner=false}）：{@code audit_status != pass} 返回 {@code null}
     * （不下发）；本人视角：三态全下，且 {@code reject} 携带 {@code reject_reason}。</p>
     *
     * @param entity  媒体实体
     * @param isOwner 是否本人视角
     * @return 媒体项；他人视角下非 pass 媒体返回 {@code null}
     */
    public MediaItem toDto(PostMediaEntity entity, boolean isOwner) {
        String auditStatus = entity.getAuditStatus();
        if (!isOwner && !MediaService.AUDIT_PASS.equals(auditStatus)) {
            return null;
        }
        String rejectReason = isOwner ? entity.getRejectReason() : null;
        return new MediaItem(
                String.valueOf(entity.getId()),
                ossClient.signAccessUrl(entity.getObjectKey()),
                auditStatus,
                rejectReason);
    }
}
