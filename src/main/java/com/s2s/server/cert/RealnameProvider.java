package com.s2s.server.cert;

/**
 * 实名核验供应商抽象（DEC-30 ⑨；[149]）。
 *
 * <p>职责：把「身份证二要素（姓名 + 身份证号）核验」抽象为单一方法，使 cert 域业务代码
 * 只依赖本接口、不感知具体供应商。换供应商（或 dry-run 切真服务）只改实现类一处，
 * 业务代码不动（DEC-30 ⑨「建 RealnameProvider 接口 + 阿里云实现」）。</p>
 *
 * <p>产品口径（DEC-30）：供应商 = 阿里云实人认证 · 信息核验 · 纯服务端 API（无客户端 SDK）；
 * 手机号一致性由已登录态保证（短信验证码登录即证明手机号归本人），<b>不向供应商传手机号、
 * 不买运营商三要素</b>。故本接口只收姓名 + 身份证号两要素。</p>
 */
public interface RealnameProvider {

    /**
     * 二要素核验（姓名 + 身份证号是否匹配）。
     *
     * @param realName 姓名明文（服务端解密前的用户输入，仅用于核验，不落任何日志）
     * @param idCard   身份证号明文（仅用于核验，不落任何日志）
     * @return {@code true} 表示核验通过（姓名与身份证号匹配）；{@code false} 表示核验不通过
     * @throws IllegalStateException 上游认证服务不可用（由调用方映射为 {@code 50302}）
     */
    boolean verify(String realName, String idCard);
}
