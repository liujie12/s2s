package com.s2s.server.common.web;

import jakarta.servlet.http.HttpServletRequest;

/**
 * 客户端 IP 解析的<b>唯一实现处</b>（[128] 上浮；编码规范 §1.1）。
 *
 * <p><b>为什么需要它</b>：限频的 IP 维（联系三维日限、未登录详情 42907、短信 IP 轨）
 * 都要求「同一个 IP 在键里写法一致」，而此前取值分散在三处
 * （{@code RateLimitInterceptor#getClientIp}、{@code AuthController#sendSmsCode}
 * 的 {@code httpRequest.getRemoteAddr()}、以及 [128] contact 所需的同一取值）。
 * 若某处改成读 {@code X-Forwarded-For} 头而其余处不跟，同一次请求会在两个键上
 * 各计一次数——<b>限频看似生效实则减半</b>，且不报任何错。</p>
 *
 * <p><b>为什么不自己解析 {@code X-Forwarded-For}</b>：部署形态是 Caddy 单入口反代，
 * 应用侧已配 {@code forward-headers-strategy: framework}（KTD2），Spring 会把
 * 代理链头的可信第一跳解析进 {@code request.getRemoteAddr()}。应用内再手工解析
 * 请求头等于自行承担「哪个跳可信」的判断，那是引入伪造 IP 绕限频的经典缺口。</p>
 */
public final class ClientIp {

    /**
     * 工具类：禁止实例化。
     */
    private ClientIp() {
        throw new AssertionError("ClientIp 是工具类，不可实例化");
    }

    /**
     * 取当前请求的真实客户端 IP。
     *
     * <p>返回值<b>永不 {@code null}</b>（{@code getRemoteAddr()} 返回 null 时给空串）：
     * 本值会直接拼进 Redis 键（如 {@code rl:contact:ip:{ip}:1d}），null 会被字符串
     * 拼接写成字面量 {@code "null"}，使所有异常请求共享同一个键、误伤彼此。</p>
     *
     * @param request 当前 HTTP 请求
     * @return {@link String} 客户端 IP（无代理头时为直连地址；取不到时空串）
     */
    public static String of(HttpServletRequest request) {
        String ip = request.getRemoteAddr();
        return ip != null ? ip : "";
    }
}
