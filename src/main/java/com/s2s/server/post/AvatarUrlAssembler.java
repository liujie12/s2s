package com.s2s.server.post;

import org.springframework.stereotype.Component;

/**
 * 用户头像 URL 组装器（2026-11-02 新增，头像编辑功能）。
 *
 * <p>职责：把 {@code user.avatar_url} 中存储的<b>稳定对象键</b>现签为可访问 URL。
 * 为什么不在写入时落签名 URL：OSS 签名只有 15 分钟有效期，落库后头像很快变成破图；
 * 为什么不在每次读取时查 {@code post_media}：地图/列表一次返回多张卡片，逐条查库
 * 会把读接口打成 N+1。对象键直接签名即可，无需再查媒体行。</p>
 *
 * <p>容错：空值返回 {@code null}；历史数据若已是绝对 URL（{@code http://} /
 * {@code https://}），原样返回，不重复签名。</p>
 */
@Component
public class AvatarUrlAssembler {

    private final OssClient ossClient;

    /**
     * 构造头像 URL 组装器。
     *
     * @param ossClient OSS 客户端（签名访问 URL）
     */
    public AvatarUrlAssembler(OssClient ossClient) {
        this.ossClient = ossClient;
    }

    /**
     * 把头像对象键解析为可访问 URL。
     *
     * @param avatarRef 头像引用（对象键；历史数据可能是绝对 URL）
     * @return {@link String} 可访问 URL；空引用返回 {@code null}
     */
    public String toUrl(String avatarRef) {
        if (avatarRef == null || avatarRef.isBlank()) {
            return null;
        }
        if (avatarRef.startsWith("http://") || avatarRef.startsWith("https://")) {
            return avatarRef;
        }
        return ossClient.signAccessUrl(avatarRef);
    }
}
