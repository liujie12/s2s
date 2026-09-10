package com.s2s.server;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * 找鸭找（s2s）后端单体服务启动类。
 *
 * <p>职责：Spring Boot 应用入口，承载 {@code com.s2s.server} 根包组件扫描；包结构定案见详设 §1.2
 * （common 七子包 + 九域 + task/，包骨架由条目[121] U-2 落地）。
 *
 * <p>技术口径：
 * <ul>
 *   <li>Java 21 + Spring Boot 3.5.16（OQ-1 钉版，理由见 pom.xml 注释）；</li>
 *   <li>KTD-3：Java 21 不开虚拟线程（退出条件：Java 24 或压测证明 I/O 阻塞）；</li>
 *   <li>单体单进程单模块（编码规范 §4.1）。</li>
 * </ul>
 *
 * <p>{@code @ConfigurationPropertiesScan} 取舍（U-5）：选扫描注册而非
 * {@code @EnableConfigurationProperties} 逐类点名——配置属性 record（当前
 * {@code common/config/SecretsProperties}，后续条目[124] 的 crypto 配置视图）新增时
 * 零装配成本，且启动类作为唯一组装根符合「common 只被依赖」（详设 §1.2）；
 * 逐类点名方案每加一个属性类都要改一处 @EnableConfigurationProperties，易漏。
 *
 * <p>启动前提（U-5 起）：业务库/埋点库连接串、Redis 口令与六类凭证全部经环境变量注入
 * （application.yml 的 {@code s2s.secrets.*} 硬占位），缺任一变量启动快速失败且报错点名变量名
 * （编码规范 §3.3）；变量清单见仓库根 .env.example。
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class S2sServerApplication {

    /**
     * 应用入口：启动 Spring Boot 上下文并随 JVM 常驻。
     *
     * @param args 命令行参数，原样透传 {@link SpringApplication#run(Class, String...)}，不做自定义解析
     * @return 无返回值（void）；进程生命周期由 Spring Boot 托管
     */
    public static void main(String[] args) {
        SpringApplication.run(S2sServerApplication.class, args);
    }
}
