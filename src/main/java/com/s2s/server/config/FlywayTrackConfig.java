package com.s2s.server.config;

import javax.sql.DataSource;

import org.flywaydb.core.Flyway;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.jdbc.DataSourceProperties;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.DependsOn;
import org.springframework.context.annotation.Primary;

/**
 * 双库数据源与 Flyway 配置（KTD-7 定案；编码规范 §4.9「Flyway 管 schema」；架构 R14 埋点与业务分库）。
 *
 * <p>库分工：
 * <ul>
 *   <li>业务库 s2s：{@link #dataSource()} 承载，{@code @Primary} 供 MyBatis-Plus、actuator db health
 *       与 spring.flyway 默认自动装配消费；迁移目录 {@code classpath:db/migration}（application.yml 声明）；</li>
 *   <li>埋点库 s2s_track：{@link #trackDataSource(String, String, String)} 承载，
 *       由 {@link #trackFlyway(DataSource)} 手动 Flyway Bean 迁移，目录 {@code classpath:db/migration_track}。</li>
 * </ul>
 *
 * <p>迁移顺序（KTD-7「在业务库 Flyway 之后/应用就绪前迁移」）：{@code trackFlyway} 以
 * {@code @DependsOn("flywayInitializer")} 排在 spring.flyway 业务库迁移执行器之后；
 * {@link SmartInitializingSingleton} 的 afterSingletonsInstantiated 在单例全部就绪后、
 * refresh 完成前触发 migrate()，早于 ApplicationReadyEvent，即应用就绪前完成。
 *
 * <p>权限前提（KTD-4）：两库的 CREATE DATABASE 与 GRANT 由 deploy/initdb.d/01-init-databases.sh
 * 在 MySQL 容器首启时以 root 完成；本类使用应用账号（无 CREATE DATABASE 权限），只负责库内表结构迁移，
 * 故 db/migration_track 副本已剔除 CREATE DATABASE/USE/GRANT 三句（KTD-5）。
 *
 * <p>快速失败：三个环境变量缺一即启动失败（{@code @Value} 无默认值硬注入），
 * 与 application.yml 的 {@code ${VAR:?}} 占位同口径（编码规范 §3.3）。
 */
@Configuration
public class FlywayTrackConfig {

    /**
     * 业务库数据源：消费 spring.datasource.*（application.yml 中的 ${SPRING_DATASOURCE_*} 占位）。
     * 显式声明并 {@code @Primary}：工程存在两个 DataSource 候选时，MyBatis-Plus、spring.flyway 自动配置
     * 与 actuator db health 一律解析到本 Bean（KTD-7）。
     *
     * <p>必须经 {@link DataSourceProperties#initializeDataSourceBuilder()} 构建（U-4 实测踩坑）：
     * HikariCP 的 URL 属性名是 {@code jdbcUrl}，没有 {@code url} 属性；若在本方法上直接挂
     * {@code @ConfigurationProperties("spring.datasource")} 绑定 HikariDataSource，
     * {@code spring.datasource.url} 会静默绑不上，启动报 "jdbcUrl is required"。
     * DataSourceProperties 由 DataSourceAutoConfiguration 完成绑定，
     * 其 builder 会把 url 正确映射到 Hikari 的 jdbcUrl。
     *
     * @param dataSourceProperties 自动装配已绑定 spring.datasource.* 的属性对象
     * @return 业务库 DataSource（classpath 内唯一连接池 HikariCP，由 DataSourceBuilder 默认选中）
     */
    @Bean
    @Primary
    public DataSource dataSource(DataSourceProperties dataSourceProperties) {
        return dataSourceProperties.initializeDataSourceBuilder().build();
    }

    /**
     * 埋点库数据源：三个环境变量名与 deploy/docker-compose.yml app 服务 environment 逐字一致；
     * 用户名/口令与业务库同一应用账号（KTD-7：仅 URL 独立）。
     *
     * @param url      埋点库 JDBC URL（TRACK_DATASOURCE_URL，库名须与 MYSQL_TRACK_DATABASE 一致）
     * @param username 应用账号（SPRING_DATASOURCE_USERNAME）
     * @param password 应用账号口令（SPRING_DATASOURCE_PASSWORD）
     * @return 埋点库 DataSource，仅供 {@link #trackFlyway(DataSource)} 消费
     */
    @Bean
    public DataSource trackDataSource(
            @Value("${TRACK_DATASOURCE_URL}") String url,
            @Value("${SPRING_DATASOURCE_USERNAME}") String username,
            @Value("${SPRING_DATASOURCE_PASSWORD}") String password) {
        return DataSourceBuilder.create()
                .url(url)
                .username(username)
                .password(password)
                .build();
    }

    /**
     * 埋点库 Flyway：手动装配并随单例初始化完成立即迁移（{@link SmartInitializingSingleton#afterSingletonsInstantiated()}
     * 在全部单例实例化后、refresh 完成前触发，早于 ApplicationReadyEvent——KTD-7「启动顺序先于应用就绪」）。
     *
     * <p>承载类型的两层退让陷阱（U-4 实测逐层定位，依据 spring-boot --debug 条件评估报告）：
     * <ul>
     *   <li>返回 {@link Flyway}：{@code FlywayAutoConfiguration.FlywayConfiguration} 的
     *       {@code @ConditionalOnMissingBean(Flyway.class)} 检测到本 Bean 后整体退让，
     *       业务库 flyway 与 flywayInitializer 均不注册；</li>
     *   <li>返回 {@code FlywayMigrationInitializer}：自动装配恢复，但 {@code #flywayInitializer}
     *       的 {@code @ConditionalOnMissingBean(FlywayMigrationInitializer.class)} 又被本 Bean 命中，
     *       flywayInitializer 仍不注册；</li>
     *   <li>故选用 {@link SmartInitializingSingleton}：与两个 MissingBean 条件均无类型交集，
     *       业务库自动装配与本 Bean 共存。</li>
     * </ul>
     *
     * <p>{@code @DependsOn("flywayInitializer")}：spring.flyway 自动配置对业务库的迁移执行器
     * （FlywayAutoConfiguration 注册的固定 Bean 名）先跑完再执行本迁移；两库独立本可并行，
     * 定案串行以便启动日志按库有序排查。
     *
     * <p>{@code @Qualifier("trackDataSource")} 必须显式标注：按类型注入时 {@code @Primary}
     * 的业务库数据源会胜出，误把业务库迁移目录指向业务库将造成两库 schema 错乱。
     *
     * @param trackDataSource 埋点库数据源（{@link #trackDataSource} 产出的 Bean）
     * @return 触发埋点库迁移的单例回调；schema history 表落在埋点库内
     *         （flyway_schema_history 默认表名，两库各自一份互不干扰）
     */
    @Bean
    @DependsOn("flywayInitializer")
    public SmartInitializingSingleton trackFlyway(@Qualifier("trackDataSource") DataSource trackDataSource) {
        return () -> Flyway.configure()
                .dataSource(trackDataSource)
                .locations("classpath:db/migration_track")
                .load()
                .migrate();
    }
}
