package com.s2s.server.common.constants;

/**
 * 浏览计数 NFR 常量（服务端单端正源；Dart 端无消费方）。
 *
 * <p>职责：承载「人/天」去重窗口与明细保留期，供浏览上报与清理任务引用，
 * 禁写死数字（编码规范红线「不复制字面量」）。</p>
 */
public final class NfrPostView {

    /**
     * 去重窗口（自然日）。同一 viewer_key 在同一自然日内只计 1 次。
     */
    public static final int DEDUPE_WINDOW_DAYS = 1;

    /**
     * 浏览明细保留天数。镜像 {@link NfrRetention#POST_VIEW_DETAIL_RETENTION_DAYS}，
     * 保留期真源仍是 NfrRetention（避免两处字面量）。
     */
    public static final int DETAIL_RETENTION_DAYS = NfrRetention.POST_VIEW_DETAIL_RETENTION_DAYS;

    /**
     * 工具类：禁止实例化。
     */
    private NfrPostView() {
        throw new AssertionError("NfrPostView 是常量类，不可实例化");
    }
}
