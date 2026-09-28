package com.s2s.server.track;

import com.s2s.server.config.TrackPersistenceConfig;
import org.apache.ibatis.session.Configuration;
import org.apache.ibatis.session.SqlSessionFactory;
import org.mybatis.spring.SqlSessionTemplate;

/**
 * 埋点库持久层入口（[129]；架构 R14 埋点分库；详设 §5.8）。
 *
 * <p><b>为什么要有这一层，而不是让埋点 Mapper 直接注入</b>：埋点数据在独立 database
 * {@code s2s_track}，其 Mapper 必须绑到 {@code trackDataSource}。而 MyBatis-Plus 自动装配的
 * {@code sqlSessionFactory}/{@code sqlSessionTemplate} 两个工厂方法都是
 * {@code @Bean @ConditionalOnMissingBean}（已 javap 字节码确证）——一旦容器里多出一个
 * {@code SqlSessionFactory} 或 {@code SqlSessionTemplate} 类型的 bean，自动装配会<b>整体退让</b>，
 * 业务库工厂连同 14 个既有 Mapper 一起消失。故本域会话由
 * {@link TrackPersistenceConfig} <b>自持</b>（构建后不注册为 bean），只把本类这个
 * 「非 MyBatis 类型」的持有器暴露成 bean，业务侧装配面零改动。</p>
 *
 * <p><b>为什么用持有器而不是暴露 {@code SqlSessionTemplate}</b>：见上——暴露它即触发同一个
 * {@code @ConditionalOnMissingBean} 退让。持有器把「一个 SqlSessionFactory 实例 + 取 Mapper 的能力」
 * 收在一处，且域外只能拿到 Mapper 接口（拿不到 SqlSessionTemplate 去执行任意语句，收敛滥用面）。</p>
 *
 * <p><b>本域 Mapper 不经 {@code @MapperScan}</b>：启动类主扫描已用 {@code excludeFilters} 排除
 * {@code com.s2s.server.track.mapper}（若被主扫描注册，会绑到业务库数据源），Mapper 一律经
 * {@link #mapper(Class)} 取得。该「分区承载」关系由常驻门禁
 * {@code MapperScanCoverageTest} 守住。</p>
 */
public final class TrackPersistence {

    /** 埋点库会话模板（自持，不注册为 bean——注册即触发自动装配退让，见类注释）。 */
    private final SqlSessionTemplate template;

    /**
     * 构造埋点库持久层入口。
     *
     * @param sqlSessionFactory 埋点库会话工厂（由 {@link TrackPersistenceConfig} 基于
     *        {@code trackDataSource} 构建，绑定的是 {@code s2s_track} 库）
     */
    public TrackPersistence(SqlSessionFactory sqlSessionFactory) {
        this.template = new SqlSessionTemplate(sqlSessionFactory);
    }

    /**
     * 取埋点库 Mapper（本域访问埋点库的唯一入口）。
     *
     * <p>行为对齐 MyBatis 的 {@code SqlSession#getMapper}，但多一步<b>幂等注册</b>：MyBatis 要求
     * 类型先 {@code addMapper} 才允许 {@code getMapper}，而本域刻意不用 {@code @MapperScan}
     * （那会注册 {@code MapperFactoryBean} 并绑错数据源），故没人替本域注册——由本方法补上。
     * 未注册时会抛 {@code BindingException: Type ... is not known to the MybatisPlusMapperRegistry}
     * （[129] P2a 实测）。</p>
     *
     * <p>注册只在首次发生（{@code hasMapper} 判定），之后是纯查表；XML 语句在会话构建时按
     * {@code mapperLocations} 加载（见 {@code TrackPersistenceConfig}）。</p>
     *
     * @param type Mapper 接口类型（须位于 {@code com.s2s.server.track.mapper} 包）
     * @param <T>  Mapper 接口类型
     * @return {@link T} Mapper 代理实例（非 null）
     */
    public <T> T mapper(Class<T> type) {
        Configuration configuration = template.getConfiguration();
        if (!configuration.hasMapper(type)) {
            configuration.addMapper(type);
        }
        return template.getMapper(type);
    }
}
