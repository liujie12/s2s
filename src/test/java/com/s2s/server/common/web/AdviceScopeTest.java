package com.s2s.server.common.web;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.web.servlet.error.BasicErrorController;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * advice 作用域测试（[122] P2 #8；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>验证 {@code @RestControllerAdvice(basePackages = "com.s2s.server")} 限定后：
 * {@link ResponseBodyWrapper} 与 {@link GlobalExceptionHandler} 只作用于
 * {@code com.s2s.server} 业务包 controller，<b>不再</b>匹配 Spring Boot 的
 * {@link BasicErrorController}（包名 {@code org.springframework.boot.autoconfigure.web.servlet.error}，
 * 承接 {@code /error} 错误派发）——否则 {@code /error} 会被套上 {@code code=0} 假成功信封
 * （#8 缺陷本质）。
 *
 * <p>测试策略：断言两 advice 的 {@code @RestControllerAdvice} 注解 basePackages 精确等于
 * {@code com.s2s.server}，并验证「业务 controller 包名在该范围内、BasicErrorController 包名
 * 不在该范围内」——basePackages 匹配语义为「包名 + 子包前缀」，故包名前缀关系即适用性判定
 * 的充分条件（纯单测，不起 Spring 容器，KTD12）。
 */
class AdviceScopeTest {

    /** 两 advice 应限定的业务根包（与生产注解 basePackages 逐字一致）。 */
    private static final String BUSINESS_BASE_PACKAGE = "com.s2s.server";

    /**
     * 场景一：{@link ResponseBodyWrapper} 的 basePackages 精确等于业务根包，
     * 业务 controller 包名在其内、BasicErrorController 包名在其外。
     *
     * @return void；断言失败即 wrapper 作用域未限定到业务包（#8 缺陷复现）
     */
    @Test
    void responseBodyWrapperScopedToBusinessPackagesOnly() {
        RestControllerAdvice annotation =
                ResponseBodyWrapper.class.getAnnotation(RestControllerAdvice.class);

        assertThat(annotation).as("ResponseBodyWrapper 须标注 @RestControllerAdvice").isNotNull();
        assertThat(annotation.basePackages()).containsExactly(BUSINESS_BASE_PACKAGE);

        assertThat(BasicErrorController.class.getPackageName())
                .as("BasicErrorController 不得落入业务包（否则 /error 套 code=0）")
                .doesNotStartWith(BUSINESS_BASE_PACKAGE);
        assertThat(DummyBusinessController.class.getPackageName())
                .as("业务 controller 须在 com.s2s.server 包下")
                .startsWith(BUSINESS_BASE_PACKAGE);
    }

    /**
     * 场景二：{@link GlobalExceptionHandler} 的 basePackages 精确等于业务根包，
     * 作用域同场景一。
     *
     * @return void；断言失败即异常 handler 作用域未限定到业务包
     */
    @Test
    void globalExceptionHandlerScopedToBusinessPackagesOnly() {
        RestControllerAdvice annotation =
                GlobalExceptionHandler.class.getAnnotation(RestControllerAdvice.class);

        assertThat(annotation).as("GlobalExceptionHandler 须标注 @RestControllerAdvice").isNotNull();
        assertThat(annotation.basePackages()).containsExactly(BUSINESS_BASE_PACKAGE);

        assertThat(BasicErrorController.class.getPackageName())
                .doesNotStartWith(BUSINESS_BASE_PACKAGE);
        assertThat(DummyBusinessController.class.getPackageName())
                .startsWith(BUSINESS_BASE_PACKAGE);
    }

    /**
     * 测试辅助业务 controller（声明于 com.s2s.server 包下，验证 basePackages 匹配）。
     * 仅作类型载体，无实际业务逻辑。
     */
    @RestController
    @RequestMapping("/dummy")
    static final class DummyBusinessController {

        /**
         * 空方法：仅提供 @RequestMapping 元信息，测试不调用。
         */
        @RequestMapping("/ping")
        public void ping() {
        }
    }
}