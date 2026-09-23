package com.s2s.server.common.constants;

/**
 * post 域 NFR 常量（[125]；单源真源镜像 Dart {@code nfr_constants.dart}）。
 *
 * <p>职责：承载发布链的时间/生命周期阈值，供 service 引用，禁写死数字
 * （编码规范红线「不复制字面量」）。</p>
 */
public final class NfrPost {

    /**
     * 帖子有效天数（镜像 Dart {@code NfrPostLifecycle.validDays = 7}）。
     */
    public static final int VALID_DAYS = 7;

    /**
     * 工具类：禁止实例化。
     */
    private NfrPost() {
        throw new AssertionError("NfrPost 是常量类，不可实例化");
    }
}
