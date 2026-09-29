package com.s2s.server.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import com.baomidou.mybatisplus.autoconfigure.MybatisPlusProperties;
import com.s2s.server.track.TrackPersistence;
import javax.sql.DataSource;
import org.apache.ibatis.session.SqlSessionFactory;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.SqlSessionTemplate;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;

/**
 * 埋点库会话装配实证（[129] 定案 A′）。
 *
 * <p><b>本测试能证明什么</b>：在 Spring 容器里装载 {@link TrackPersistenceConfig} 后，
 * ① 容器中<b>不存在</b> {@code SqlSessionFactory} 与 {@code SqlSessionTemplate} 类型的 bean；
 * ② {@link TrackPersistence} bean 可用且能产出 Mapper 代理（即会话真的建起来了）。
 * ①是「不会触发 MyBatis-Plus 自动装配退让」的结构性证明（退让条件为
 * {@code @ConditionalOnMissingBean}，已 javap 实证），②是「会话可用」的功能证明。
 * 用桩 {@code DataSource} 即可（{@code MybatisSqlSessionFactoryBean#getObject()} 只组装
 * 会话工厂，不建立连接），因此本测试不依赖 MySQL/Redis。</p>
 *
 * <p><b>本测试不能证明什么</b>：业务库那套自动装配在本配置存在时依旧生效——那需要真启动
 * 整个应用（本地无 MySQL/Redis，全库也无 {@code @SpringBootTest}）。该点由 [130] 联调首启时
 * 实证（启动成功本身即证明；另可查 {@code information_schema} 确认 track 表落在
 * {@code s2s_track} 库）。此限制已登记在说明文档的 [129] 进度记录里。</p>
 */
class TrackPersistenceConfigTest {

    /**
     * 测试用空 Mapper 接口：仅验证「会话能产出 Mapper 代理」。
     *
     * <p>刻意不带任何方法：MyBatis 取 Mapper 时只登记接口，语句在执行时绑定，
     * 故无需（也不该）为一个装配测试去造 track 的真实 Mapper 与 XML。</p>
     */
    interface MarkerMapper {
    }

    /**
     * 断言埋点会话自持：不暴露 MyBatis 类型 bean，且可取到 Mapper 代理。
     *
     * <p>【功能】以最小容器装载本配置（桩数据源 + 默认 {@code MybatisPlusProperties}），
     * 断言两类 MyBatis bean 缺席、持有器可产出 Mapper 代理。</p>
     * <p>【参数】无。</p>
     * <p>【返回】void；任一断言失败即装配形态被破坏（例如有人把 SqlSessionFactory 注册成 bean，
     * 会让业务库 14 个既有 Mapper 在启动期集体失败）。</p>
     */
    @Test
    @DisplayName("埋点会话自持：不暴露 SqlSessionFactory/SqlSessionTemplate bean，且能取到 Mapper 代理")
    void buildsTrackSessionWithoutExposingMyBatisBeans() {
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.registerBean("trackDataSource", DataSource.class, () -> mock(DataSource.class));
            context.registerBean(MybatisPlusProperties.class, MybatisPlusProperties::new);
            context.register(TrackPersistenceConfig.class);
            context.refresh();

            assertThat(context.getBeanNamesForType(SqlSessionFactory.class))
                    .as("一旦暴露 SqlSessionFactory 类型 bean，MybatisPlusAutoConfiguration 会整体退让，"
                            + "业务库工厂连同既有 Mapper 全部装配失败")
                    .isEmpty();
            assertThat(context.getBeanNamesForType(SqlSessionTemplate.class))
                    .as("SqlSessionTemplate 同样是 @ConditionalOnMissingBean 的目标类型，不得暴露")
                    .isEmpty();
            assertThat(context.getBean(TrackPersistence.class).mapper(MarkerMapper.class))
                    .as("埋点会话可用：持有器应能产出 Mapper 代理")
                    .isNotNull();
        }
    }
}
