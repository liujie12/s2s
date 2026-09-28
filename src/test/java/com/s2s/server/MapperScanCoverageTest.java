package com.s2s.server;

import static org.assertj.core.api.Assertions.assertThat;

import java.beans.Introspector;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.annotation.MapperScan;
import org.mybatis.spring.mapper.ClassPathMapperScanner;
import org.springframework.context.annotation.AnnotationBeanNameGenerator;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.core.type.filter.RegexPatternTypeFilter;

/**
 * 启动期装配门禁：每个 Mapper 接口必须<b>恰被一种机制承载</b>——启动类的主 {@code @MapperScan}，
 * 或「手工会话承载」声明（见 {@link #MANUAL_SESSION_PACKAGES}）。
 *
 * <p><b>为什么需要本门禁</b>（[128] code review finding #1 实测确证后固化）：
 * {@code @MapperScan} 会注册 {@code MapperScannerConfigurer}，而
 * mybatis-spring-boot-autoconfigure 的自动扫描注册器被
 * {@code @ConditionalOnMissingBean({MapperFactoryBean, MapperScannerConfigurer})}
 * 挡着——因此<b>只要启动类有 {@code @MapperScan}，自动扫描就被关掉</b>，
 * {@code @Mapper} 注解自身不注册 bean。此时若某个 Mapper 的包名不以
 * {@code .mapper} 结尾，它扫不到，注入它的组件会在<b>启动那一刻</b>才失败。
 * 全库原先没有任何装配测试（切片单测全绿也照旧漏），故本门禁守这条不变量。</p>
 *
 * <p><b>[129] 起的第二个失效面</b>（定案 A′）：埋点库 {@code s2s_track} 有独立会话
 * （{@code TrackPersistenceConfig}，自持不暴露 {@code SqlSessionFactory} 以免 MyBatis-Plus
 * 自动装配整体退让），其 Mapper 由启动类的 {@code excludeFilters} 排除在主扫描之外。
 * 于是同一个 Mapper 有两种承载方式，且**两种都会出问题**：
 * ① 谁都不承载 → 启动期注入失败；② 两边都承载 → 埋点 Mapper 被绑到业务库数据源（写错库）。
 * 本门禁因此从「全覆盖」升级为「<b>恰好一种</b>」的分区判据。</p>
 *
 * <p>判据取自启动类的注解而非硬编码 pattern（含 {@code excludeFilters}）：启动类改了注解，
 * 本门禁跟着变，不会出现「门禁守着旧值、应用用着新值」的静默漂移。</p>
 */
class MapperScanCoverageTest {

    /** 主源码根（与 {@code CryptoFacadeCallSiteTest} 同约定：测试工作目录为仓库根）。 */
    private static final Path MAIN_JAVA_ROOT = Path.of("src", "main", "java");

    /** Mapper 接口的文件名后缀。 */
    private static final String MAPPER_FILE_SUFFIX = "Mapper.java";

    /**
     * 「手工会话承载」声明：包名（精确匹配）→ 理由。
     *
     * <p>语义：这些包下的 Mapper <b>不经</b>启动类主 {@code @MapperScan}（该包已被
     * {@code excludeFilters} 排除），由独立会话装配；门禁据此不要求主 pattern 覆盖它们，
     * 但要求它们<b>确实没被主 pattern 注册</b>（防两边都注册）。</p>
     *
     * <p><b>空表是合法状态</b>：[129] P2a 只落装配骨架、尚无 track Mapper；P2b 落地首个
     * track Mapper 时在此登记。登记前该 Mapper 会被判「谁都不承载」而报红——这正是期望的
     * 提示（不允许悄悄出现一个无人承载的 Mapper）。</p>
     */
    private static final Map<String, String> MANUAL_SESSION_PACKAGES = new LinkedHashMap<>();

    /**
     * 断言每个 Mapper 恰被一种机制承载。
     *
     * <p>【功能】读启动类注解取主 pattern 与排除过滤器，以 MyBatis 自己的扫描器真跑一遍得到
     * 实际注册面，再对源码树枚举出的每个 Mapper 判定承载方式（见
     * {@link #judgeMapperCoverage(List, Set, Map)}）。</p>
     * <p>【参数】无。</p>
     * <p>【返回】void；任一 Mapper 的承载方式不合法即断言失败，失败信息含具体类型与原因。</p>
     */
    @Test
    @DisplayName("每个 Mapper 恰被一种机制承载：主 @MapperScan 或手工会话（且不得双重/遗漏）")
    // 刻意用 ClassPathMapperScanner 的「已弃用且待删除」构造器：该版本里它只有一个
    // 构造器，且正是 MapperScannerConfigurer 内部驱动扫描所用的同一入口——本判据要验的
    // 就是「真实扫描机制」而非等价复刻，没有非过时的替代品可选。javac 对 forRemoval
    // 归入 removal 分类（故两个分类都抑制），弃用标记只表示 mybatis-spring 计划重构该
    // API，不影响本判据的有效性。
    @SuppressWarnings({"removal", "deprecation"})
    void everyMapperIsCarriedByExactlyOneMechanism() {
        String pattern = applicationMapperScanPattern();
        List<RegexPatternTypeFilter> excludeFilters = applicationMapperScanExcludeFilters();
        List<String> mapperTypes = mapperTypesUnderMainSources();
        Set<String> registeredBeanNames = registeredBeanNames(pattern, excludeFilters);

        // 判据 1（保留自 [128] 修复）：包名须以 .mapper 结尾——先于扫描器失败，直接点名文件与包
        List<String> wrongPackage = mapperTypes.stream()
                .filter(type -> !packageOf(type).endsWith(".mapper"))
                .toList();
        assertThat(wrongPackage)
                .as("这些 Mapper 的包名不以 .mapper 结尾，@MapperScan(\"%s\") 扫不到：%s", pattern, wrongPackage)
                .isEmpty();

        // 判据 2：分区承载（真扫描结果 + 手工会话声明）
        String verdict = judgeMapperCoverage(mapperTypes, registeredBeanNames, MANUAL_SESSION_PACKAGES);
        assertThat(verdict)
                .as("Mapper 承载方式不合法（详设 §1.2 包结构 + [129] 定案 A′）")
                .isNull();
    }

    /**
     * 变异自检：判据本身要被证伪——对每种破坏形状都必须判红，对合法形状不得误报。
     *
     * <p>合成输入不与仓库现状耦合，只验证判据的判别力（同 {@code CryptoFacadeCallSiteTest} 范式）。</p>
     *
     * @return void；断言失败即判据存在静默面（漏判 = 门禁形同虚设）
     */
    @Test
    @DisplayName("[变异自检] 分区判据：该红必红、不该红不红")
    void judgementRejectsEachBrokenShape() {
        String businessMapper = "com.s2s.server.contact.mapper.ReportMapper";
        String trackMapper = "com.s2s.server.track.mapper.TrackEventMonthMapper";
        Map<String, String> declared = Map.of("com.s2s.server.track.mapper", "埋点库独立会话承载");
        Set<String> mainOnly = Set.of(beanNameOf(businessMapper));

        // 合法：主扫描覆盖业务 Mapper、track Mapper 由手工会话承载
        assertThat(judgeMapperCoverage(List.of(businessMapper, trackMapper), mainOnly, declared)).isNull();
        // 合法：尚无手工会话 Mapper（[129] P2a 现状）
        assertThat(judgeMapperCoverage(List.of(businessMapper), mainOnly, Map.of())).isNull();

        // 破坏 1：谁都不承载（漏配 @MapperScan 或包名写错）
        assertThat(judgeMapperCoverage(List.of(businessMapper), Set.of(), Map.of())).isNotNull();
        // 破坏 2：双重承载（track Mapper 又被主扫描注册 → 会绑到业务库数据源）
        assertThat(judgeMapperCoverage(List.of(businessMapper, trackMapper),
                Set.of(beanNameOf(businessMapper), beanNameOf(trackMapper)), declared)).isNotNull();
        // 破坏 3：声明过期（该包下已无 Mapper 却仍挂在声明表 → 永绿豁免）
        assertThat(judgeMapperCoverage(List.of(businessMapper), mainOnly, declared)).isNotNull();
        // 破坏 4：空扫描面（源目录遍历失真）
        assertThat(judgeMapperCoverage(List.of(), Set.of(), Map.of())).isNotNull();
    }

    /**
     * 判据纯函数：给定「全部 Mapper」「主扫描实际注册的 bean 名」「手工会话声明」，
     * 返回 {@code null}（通过）或失败原因。
     *
     * @param mapperTypes          主源码下全部 Mapper 的全限定名
     * @param registeredBeanNames  主 {@code @MapperScan} 实际注册的 bean 名集合（真扫描结果）
     * @param manualSessionPackages 手工会话承载声明（包名 → 理由）
     * @return {@link String}；{@code null} 表示每个 Mapper 恰被一种机制承载
     */
    static String judgeMapperCoverage(List<String> mapperTypes, Set<String> registeredBeanNames,
            Map<String, String> manualSessionPackages) {
        if (mapperTypes.isEmpty()) {
            return "扫描面为空：主源码下未发现任何 Mapper 接口（空扫描是失真，不是通过）";
        }
        List<String> both = new ArrayList<>();
        List<String> neither = new ArrayList<>();
        for (String mapperType : mapperTypes) {
            boolean registered = registeredBeanNames.contains(beanNameOf(mapperType));
            boolean manual = manualSessionPackages.containsKey(packageOf(mapperType));
            if (registered && manual) {
                both.add(mapperType);
            }
            if (!registered && !manual) {
                neither.add(mapperType);
            }
        }
        if (!both.isEmpty()) {
            return "这些 Mapper 同时被主 @MapperScan 与手工会话声明承载（会被注册到错误的数据源）：" + both;
        }
        if (!neither.isEmpty()) {
            return "这些 Mapper 既未被主 @MapperScan 覆盖、也未登记为手工会话承载（注入它的组件会在启动期失败）："
                    + neither;
        }
        List<String> staleDeclarations = manualSessionPackages.keySet().stream()
                .filter(pkg -> mapperTypes.stream().noneMatch(type -> packageOf(type).equals(pkg)))
                .toList();
        if (!staleDeclarations.isEmpty()) {
            return "手工会话声明存在过期项：这些包下已无任何 Mapper，声明却仍挂着（会替将来真正的同名偏差挡枪）："
                    + staleDeclarations;
        }
        return null;
    }

    /**
     * 取启动类上 {@code @MapperScan} 声明的扫描 pattern。
     *
     * @return {@link String} 启动类的扫描 pattern（取注解 value 的首项）
     * @throws AssertionError 注解缺失或未声明 value 时抛出（fail-closed：取不到 pattern
     *         就不能假装判据成立）
     */
    private String applicationMapperScanPattern() {
        MapperScan annotation = S2sServerApplication.class.getAnnotation(MapperScan.class);
        assertThat(annotation)
                .as("启动类 %s 必须声明 @MapperScan——本门禁据它取 pattern", S2sServerApplication.class.getName())
                .isNotNull();
        String[] declared = annotation.value();
        assertThat(declared)
                .as("启动类 @MapperScan 必须用 value 声明扫描 pattern（本门禁只读 value）")
                .isNotEmpty();
        return declared[0];
    }

    /**
     * 取启动类 {@code @MapperScan} 声明的排除过滤器（转成 MyBatis 扫描器可用的形态）。
     *
     * <p>只支持 {@code FilterType.REGEX}：本门禁要以「真实扫描机制」复现排除效果，而
     * {@code RegexPatternTypeFilter} 正是 Spring 处理 REGEX 过滤器的同一实现；遇到其它过滤
     * 类型直接失败（fail-closed）而不是跳过——跳过会让判据悄悄比应用宽松。</p>
     *
     * @return {@link List} 排除过滤器；无声明时为空列表
     * @throws AssertionError 出现非 REGEX 过滤类型，或 REGEX 未给出 pattern 时抛出
     */
    private List<RegexPatternTypeFilter> applicationMapperScanExcludeFilters() {
        MapperScan annotation = S2sServerApplication.class.getAnnotation(MapperScan.class);
        assertThat(annotation).isNotNull();
        List<RegexPatternTypeFilter> filters = new ArrayList<>();
        for (ComponentScan.Filter filter : annotation.excludeFilters()) {
            assertThat(filter.type())
                    .as("本门禁只复现 REGEX 排除过滤器；出现 %s 时无法机械复现（fail-closed）", filter.type())
                    .isEqualTo(FilterType.REGEX);
            // @ComponentScan.Filter 的 value() 是 Class<?>[]（ASSIGNABLE_TYPE 用），排除表达式的
            // 唯一入口是 pattern()——REGEX 过滤器必须走它。
            String[] patterns = filter.pattern();
            assertThat(patterns)
                    .as("@MapperScan 的 REGEX 排除过滤器必须用 pattern 给出表达式")
                    .isNotEmpty();
            filters.add(new RegexPatternTypeFilter(Pattern.compile(patterns[0])));
        }
        return filters;
    }

    /**
     * 以启动类同一 pattern 与排除过滤器驱动 MyBatis 扫描器，取实际注册的 bean 名。
     *
     * @param pattern       启动类主 {@code @MapperScan} 的扫描 pattern
     * @param excludeFilters 启动类主 {@code @MapperScan} 的排除过滤器
     * @return {@link Set} 实际注册的 bean 名集合
     */
    private Set<String> registeredBeanNames(String pattern, List<RegexPatternTypeFilter> excludeFilters) {
        try (GenericApplicationContext context = new GenericApplicationContext()) {
            ClassPathMapperScanner scanner = new ClassPathMapperScanner(context);
            scanner.setResourceLoader(new PathMatchingResourcePatternResolver());
            scanner.setBeanNameGenerator(new AnnotationBeanNameGenerator());
            scanner.setEnvironment(context.getEnvironment());
            scanner.registerFilters();
            for (RegexPatternTypeFilter excludeFilter : excludeFilters) {
                scanner.addExcludeFilter(excludeFilter);
            }
            scanner.scan(pattern);
            return new LinkedHashSet<>(Arrays.asList(context.getBeanDefinitionNames()));
        }
    }

    /**
     * 枚举主源码下全部 Mapper 接口的全限定名。
     *
     * @return {@link List} 全限定名列表（按路径排序，失败信息稳定可读）
     * @throws UncheckedIOException 遍历源码树失败时抛出（不吞异常：读不到源码即判据失真）
     */
    private List<String> mapperTypesUnderMainSources() {
        assertThat(Files.isDirectory(MAIN_JAVA_ROOT))
                .as("主源码目录 %s 必须存在——不存在即扫描面失真，按失败处理", MAIN_JAVA_ROOT)
                .isTrue();
        try (Stream<Path> paths = Files.walk(MAIN_JAVA_ROOT)) {
            return paths
                    .filter(Files::isRegularFile)
                    .filter(path -> path.getFileName().toString().endsWith(MAPPER_FILE_SUFFIX))
                    .map(this::toFullyQualifiedName)
                    .sorted()
                    .toList();
        } catch (IOException exception) {
            throw new UncheckedIOException(exception);
        }
    }

    /**
     * 源码路径 → 全限定名。
     *
     * @param javaFile 主源码根下的 .java 文件路径
     * @return {@link String} 全限定类名（分隔符换点、去 .java 后缀）
     */
    private String toFullyQualifiedName(Path javaFile) {
        String relative = MAIN_JAVA_ROOT.relativize(javaFile).toString();
        return relative.replace('\\', '.').replace('/', '.').replaceAll("\\.java$", "");
    }

    /**
     * 取全限定名的包名部分。
     *
     * @param fullyQualifiedName 全限定类名
     * @return {@link String} 包名；无包名时返回空串
     */
    static String packageOf(String fullyQualifiedName) {
        int lastDot = fullyQualifiedName.lastIndexOf('.');
        return lastDot < 0 ? "" : fullyQualifiedName.substring(0, lastDot);
    }

    /**
     * 取 Mapper 在 Spring 容器中的预期 bean 名。
     *
     * <p>与扫描器实际使用的 {@link AnnotationBeanNameGenerator} 同口径：类名首字母小写。</p>
     *
     * @param fullyQualifiedName 全限定类名
     * @return {@link String} 预期 bean 名
     */
    static String beanNameOf(String fullyQualifiedName) {
        String simpleName = fullyQualifiedName.substring(fullyQualifiedName.lastIndexOf('.') + 1);
        return Introspector.decapitalize(simpleName);
    }
}
