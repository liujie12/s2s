package com.s2s.server.common.constants;

import java.util.Set;

/**
 * 媒体域 NFR 常量（[125]；单源真源对齐 openapi 契约与 PRD §13.2）。
 *
 * <p>职责：承载媒体数量/类型/大小阈值，供 ticket 校验引用，禁写死数字。</p>
 */
public final class NfrMedia {

    /**
     * 单帖媒体数量上限（openapi {@code media_ids maxItems: 9}）。
     */
    public static final int MAX_MEDIA_COUNT = 9;

    /**
     * 允许的图片 MIME 白名单（openapi {@code content_type enum}）。
     */
    public static final Set<String> ALLOWED_CONTENT_TYPES =
            Set.of("image/jpeg", "image/png", "image/webp");

    /**
     * 单文件字节上限。
     *
     * <p><b>TODO（Open Question）</b>：本值真源未定——PRD §13.2 仅给「媒体合计
     * ≤200MB / 图片 ≤9」，无单文件上限；现为占位值，实现前须向用户索取权威值，
     * 禁猜值。</p>
     */
    public static final int MAX_SIZE_BYTES = 20 * 1024 * 1024;

    /**
     * 工具类：禁止实例化。
     */
    private NfrMedia() {
        throw new AssertionError("NfrMedia 是常量类，不可实例化");
    }
}
