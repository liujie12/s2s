package com.s2s.server;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

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
 * <p>启动前提：数据源（业务库 s2s / 埋点库 s2s_track）与 Redis 在 U-5 才完成外部化配置；
 * 当前 U-1 阶段 Flyway 在 classpath 而无可达数据库，应用无法启动属预期（U-1 仅要求编译与空测试套通过）。
 */
@SpringBootApplication
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
