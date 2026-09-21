package com.s2s.server.auth;

/**
 * auth 域 NFR 常量（[123] U5；详设 §5.1、PRD §3.7）。
 *
 * <p>承载登录会话 Token 有效期等 auth 域专属 NFR 常量，供 {@link AuthService}
 * 签发/续期时引用（「不复制字面量」红线：阈值/TTL 只引用常量名）。本类为
 * Java 单端正源——前端 {@code auth_repository.dart} 的 {@code Duration(days: 30)}
 * 属 mock 内联值（未抽象为命名常量），故不设 Dart 镜像对账。</p>
 */
public final class NfrAuth {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private NfrAuth() {
        throw new AssertionError("NfrAuth 是常量类，不可实例化");
    }

    /**
     * 登录会话 Token 有效期（天）= 30。详设 §5.1「签发 JWT（30 天）」；PRD §3.7
     * 「JWT / 自有 Token，有效期 30 天，自动续期」；plan KTD2「exp = iat + 30 天」。
     *
     * <p>消费口径：秒数换算由消费方用 {@code Duration.ofDays(NfrAuth.TOKEN_TTL_DAYS)}
     * 完成，本类不提供预乘的秒常量（30*24*3600）——预乘值一旦散落即复制字面量
     * （范式同 {@code NfrApi#IDEMPOTENCY_WINDOW_HOURS}）。</p>
     */
    public static final int TOKEN_TTL_DAYS = 30;
}
