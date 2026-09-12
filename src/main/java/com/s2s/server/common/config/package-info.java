/**
 * 通用配置属性包。
 *
 * <p>职责：承载跨域共享的 {@code @ConfigurationProperties} 绑定类型。当前仅
 * {@code SecretsProperties}（六类凭证绑定载体，编码规范 §3.3 缺变量启动快速失败的落点）；
 * 后续新增的配置属性 record（如条目[124] crypto 解析后的密钥视图）经
 * {@code S2sServerApplication} 的 {@code @ConfigurationPropertiesScan} 自动注册，无需逐类装配。
 *
 * <p>出处：详设 §1.2（common 只被依赖）；编码规范 §3.3（配置与密钥）。
 */
package com.s2s.server.common.config;
