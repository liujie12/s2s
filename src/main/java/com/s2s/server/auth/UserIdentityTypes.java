package com.s2s.server.auth;

/**
 * {@code user_identity.identity_type} 枚举值的<b>唯一常量源</b>。
 *
 * <p>为什么单独成类：身份类型字符串在 auth 域（登录/绑定/资料投影）与
 * 风控守卫（发布/联系门禁）多处出现，第二处复制字面量即违反编码规范 §1.1；
 * 数据库 ENUM 与契约枚举均以本类为准（新增 apple 时只改这里与 DDL）。</p>
 */
public final class UserIdentityTypes {

    /**
     * 私有构造器：常量类禁止实例化。
     */
    private UserIdentityTypes() {
        throw new AssertionError("UserIdentityTypes 是常量类，不可实例化");
    }

    /** 手机号身份（登录主标识）。 */
    public static final String PHONE = "phone";

    /** 微信开放平台身份（unionid，B2-6a）。 */
    public static final String WECHAT = "wechat";

    /** Apple 身份（App Store 4.8 要求与微信同批交付，预留）。 */
    public static final String APPLE = "apple";
}
