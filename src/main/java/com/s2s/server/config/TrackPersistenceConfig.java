package com.s2s.server.config;

import com.baomidou.mybatisplus.autoconfigure.MybatisPlusProperties;
import com.baomidou.mybatisplus.core.MybatisConfiguration;
import com.baomidou.mybatisplus.core.config.GlobalConfig;
import com.baomidou.mybatisplus.core.toolkit.GlobalConfigUtils;
import com.baomidou.mybatisplus.spring.MybatisSqlSessionFactoryBean;
import com.s2s.server.track.TrackPersistence;
import javax.sql.DataSource;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/**
 * 埋点库 MyBatis 会话装配（[129] 定案 A′；架构 R14 埋点分库；详设 §5.8）。
 *
 * <p><b>为什么会话要「自持」而不注册成 bean</b>（本条目的全部存在理由）：
 * {@code MybatisPlusAutoConfiguration#sqlSessionFactory(DataSource)} 与
 * {@code #sqlSessionTemplate(SqlSessionFactory)} 都标注了 {@code @Bean @ConditionalOnMissingBean}
 * （已用 {@code javap -v} 对 3.5.17 字节码确证）。这意味着：容器里只要出现<b>任意一个</b>
 * {@code SqlSessionFactory}（或 {@code SqlSessionTemplate}）类型的 bean，MyBatis-Plus 自动装配就
 * <b>整体退让</b>——业务库工厂不再创建，14 个既有 Mapper（auth/category/post/map/contact/audit/
 * observability…）全部注入失败，<b>启动即挂</b>。本仓库全库无 {@code @SpringBootTest}、本地无
 * MySQL/Redis，这类装配事故在本地单测里拦不住（[128] 的 P0 就是同型问题在真启动时才暴露的）。
 *
 * <p>故本配置把埋点库会话构造出来后<b>只交给 {@link TrackPersistence} 持有</b>，不注册为
 * {@code SqlSessionFactory}/{@code SqlSessionTemplate} 类型的 bean：对外唯一可见的 bean 是
 * {@code TrackPersistence} 这个非 MyBatis 类型，业务侧装配面零改动。
 * 代价是埋点 Mapper 不经 {@code @MapperScan}（启动类主扫描已排除
 * {@code com.s2s.server.track.mapper}，否则它们会绑到业务库数据源），改由
 * {@link TrackPersistence#mapper(Class)} 取得——分区承载关系由常驻门禁
 * {@code MapperScanCoverageTest} 守住。</p>
 *
 * <p><b>为什么用 {@link MybatisSqlSessionFactoryBean} 而不是原生 {@code SqlSessionFactoryBean}</b>：
 * 前者才带 MyBatis-Plus 的 SQL 注入器（BaseMapper 能力）与 {@link GlobalConfig}；用原生类会让本域
 * 会话成为「半个 MyBatis」，两条会话的行为差异会在最不该出问题的写入路径上发作。</p>
 *
 * <p><b>口径同源</b>：{@code map-underscore-to-camel-case} 与 {@code id-type} 一律从
 * {@link MybatisPlusProperties}（即 {@code application.yml} 的 {@code mybatis-plus.*} 绑定结果）复制，
 * 不在本类重写一份——否则两套口径会各自漂移（不复制字面量纪律）。</p>
 *
 * <p><b>XML 加载</b>：不显式设置 {@code mapperLocations}，沿用 MyBatis-Plus 默认的
 * {@code classpath*:/mapper/**} 扫描面，故本域 XML 落 {@code src/main/resources/mapper/} 下即可被加载
 * （本域暂无 XML，抽象语句随 P2b 落地；无匹配资源不会导致启动失败——{@code resolveMapperLocations}
 * 对 IOException 返回空数组）。</p>
 */
@Configuration
public class TrackPersistenceConfig {

    /**
     * 下划线转驼峰的配置键（与 {@code application.yml} 的 {@code mybatis-plus.*} 同键名）。
     *
     * <p>为什么不读 {@code MybatisPlusProperties#getConfiguration()}：3.5.17 里它返回的是
     * <b>组合式</b>的 {@code MybatisPlusProperties$CoreConfiguration}（内含一个
     * {@code MybatisConfiguration}，非继承），拿不到值又平添一层耦合；直接读配置源（Environment）
     * 才是「口径唯一真源」——{@code application.yml} 改了，本会话跟着改。</p>
     */
    private static final String PROPERTY_MAP_UNDERSCORE_TO_CAMEL_CASE =
            "mybatis-plus.configuration.map-underscore-to-camel-case";

    /**
     * 构建埋点库持久层入口（自持会话，不暴露 MyBatis 类型 bean）。
     *
     * @param trackDataSource      埋点库数据源（{@code FlywayTrackConfig#trackDataSource}，库名
     *                             {@code s2s_track}；按 {@link Qualifier} 显式指定，避免命中的
     *                             {@code @Primary} 业务库数据源）
     * @param mybatisPlusProperties {@code mybatis-plus.*} 的绑定结果（本类只从它复制口径，不自己写值）
     * @param environment          配置源；用于取 {@code map-underscore-to-camel-case}
     *                             （缺省 true，与 MyBatis-Plus 自身默认一致）
     * @return {@link TrackPersistence} 埋点库唯一访问入口
     * @throws IllegalStateException 会话构建失败时抛出（启动期快速失败：埋点会话起不来意味着
     *         埋点数据静默丢失，而埋点是北极星验收的阻塞项）
     */
    @Bean
    public TrackPersistence trackPersistence(
            @Qualifier("trackDataSource") DataSource trackDataSource,
            MybatisPlusProperties mybatisPlusProperties,
            Environment environment) {
        MybatisSqlSessionFactoryBean factory = new MybatisSqlSessionFactoryBean();
        factory.setDataSource(trackDataSource);

        MybatisConfiguration configuration = new MybatisConfiguration();
        configuration.setMapUnderscoreToCamelCase(environment.getProperty(
                PROPERTY_MAP_UNDERSCORE_TO_CAMEL_CASE, Boolean.class, Boolean.TRUE));
        factory.setConfiguration(configuration);

        GlobalConfig globalConfig = GlobalConfigUtils.defaults();
        GlobalConfig boundGlobalConfig = mybatisPlusProperties.getGlobalConfig();
        if (boundGlobalConfig != null && boundGlobalConfig.getDbConfig() != null) {
            // id-type 必须与业务库同为 auto：埋点两张表的 id 是 AUTO_INCREMENT，
            // 若继承 MyBatis-Plus 默认的雪花算法，insert 会写入一个与自增列无关的 id。
            globalConfig.getDbConfig().setIdType(boundGlobalConfig.getDbConfig().getIdType());
        }
        factory.setGlobalConfig(globalConfig);

        try {
            return new TrackPersistence(factory.getObject());
        } catch (Exception exception) {
            throw new IllegalStateException(
                    "埋点库 MyBatis 会话构建失败（埋点写入将全部失效）", exception);
        }
    }
}
