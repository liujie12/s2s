package com.s2s.server.common.web;

import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/**
 * 测试夹具：{@link RequestContextHolder} 请求上下文脚手架（包私有，仅供本包测试类使用）。
 *
 * <p>提取原因：{@link GlobalExceptionHandlerTest} 与 {@link ResponseBodyWrapperTest} 的
 * setUp/tearDown 曾重复同一套「建 Mock 请求 → 写 {@code REQUEST_ID_ATTRIBUTE} 属性 →
 * setRequestAttributes / resetRequestAttributes」脚手架，仅预置 request_id 值不同——
 * 同一逻辑出现第 2 次必须提取为共享实现（编码规范 §1.1），本类即唯一实现处。
 *
 * <p>request_id 属性键引用 {@link ResponseBodyWrapper#REQUEST_ID_ATTRIBUTE} 公共常量，
 * 不复制字面量（编码规范 §0.2）；[122] {@code RequestIdFilter} 已在生产链首生成并写入
 * 同一属性键，纯单测经本夹具直接设置该键、绕过完整 Filter 链（KTD12 纯单测策略），
 * 与生产侧读取路径保持同一属性键。
 */
final class RequestContextFixtures {

    /** 工具类仅承载静态方法，禁止实例化。 */
    private RequestContextFixtures() {
    }

    /**
     * 安装带预置 {@code request_id} 的 Mock 请求到当前线程的 {@link RequestContextHolder}，
     * 模拟请求线程上下文（被测代码经请求属性逐字读取该值）。
     *
     * @param requestId 预置的 {@code request_id}，逐字写入请求属性
     * @return void
     */
    static void install(String requestId) {
        MockHttpServletRequest contextRequest = new MockHttpServletRequest();
        contextRequest.setAttribute(ResponseBodyWrapper.REQUEST_ID_ATTRIBUTE, requestId);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(contextRequest));
    }

    /**
     * 清空当前线程的请求上下文，避免测试间串扰。
     *
     * @return void
     */
    static void clear() {
        RequestContextHolder.resetRequestAttributes();
    }
}
