package com.s2s.server;

import static org.assertj.core.api.Assertions.assertThat;

import java.beans.Introspector;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.annotation.MapperScan;
import org.mybatis.spring.mapper.ClassPathMapperScanner;
import org.springframework.context.annotation.AnnotationBeanNameGenerator;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;

/**
 * 启动期装配门禁：{@code @MapperScan} 必须覆盖全部 Mapper 接口。
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
 * <p>判据取自启动类的注解而非硬编码 pattern：启动类改了 pattern，本门禁跟着变，
 * 不会出现「门禁守着旧值、应用用着新值」的静默漂移。</p>
 *
 * <p>两个判据互补：判据 1 用源码路径直接给出可定位的失败信息（哪个文件、什么包名）；
 * 判据 2 用 MyBatis 自己的扫描器走完整机制，兜住「包名合法但实际未被扫到」的其它成因。</p>
 */
class MapperScanCoverageTest {

    /** 主源码根（与 {@code CryptoFacadeCallSiteTest} 同约定：测试工作目录为仓库根）。 */
    private static final Path MAIN_JAVA_ROOT = Path.of("src", "main", "java");

    /** Mapper 接口的文件名后缀。 */
    private static final String MAPPER_FILE_SUFFIX = "Mapper.java";

    /**
     * 断言启动类的 {@code @MapperScan} pattern 覆盖本仓库全部 Mapper 接口。
     *
     * <p>【功能】读启动类注解取 pattern，枚举主源码下的 Mapper 接口，先校验包名后缀，
     * 再以同一 pattern 驱动 MyBatis 扫描器逐个断言已注册为 bean。</p>
     * <p>【参数】无。</p>
     * <p>【返回】void；任一 Mapper 未被覆盖即断言失败，失败信息含具体类型与 pattern。</p>
     */
    @Test
    @DisplayName("@MapperScan pattern 必须覆盖全部 Mapper 接口，否则启动期注入失败")
    // 刻意用 ClassPathMapperScanner 的「已弃用且待删除」构造器：该版本里它只有一个
    // 构造器，且正是 MapperScannerConfigurer 内部驱动扫描所用的同一入口——本判据要验的
    // 就是「真实扫描机制」而非等价复刻，没有非过时的替代品可选。javac 对 forRemoval
    // 归入 removal 分类（故两个分类都抑制），弃用标记只表示 mybatis-spring 计划重构该
    // API，不影响本判据的有效性。
    @SuppressWarnings({"removal", "deprecation"})
    void mapperScanPatternReachesEveryMapperInterface() {
        String pattern = applicationMapperScanPattern();
        List<String> mapperTypes = mapperTypesUnderMainSources();

        // 防空扫：扫描面为空时本判据会「永绿」，必须先挡掉这种失真
        assertThat(mapperTypes)
                .as("源目录 %s 下应至少存在一个 Mapper 接口（空集合会让本判据失去意义）", MAIN_JAVA_ROOT)
                .isNotEmpty();

        // 判据 1：包名须以 .mapper 结尾——先于扫描器失败，直接点名文件与包
        List<String> wrongPackage = mapperTypes.stream()
                .filter(type -> !packageOf(type).endsWith(".mapper"))
                .toList();
        assertThat(wrongPackage)
                .as("这些 Mapper 的包名不以 .mapper 结尾，@MapperScan(\"%s\") 扫不到：%s", pattern, wrongPackage)
                .isEmpty();

        // 判据 2：以启动类同一 pattern 驱动 MyBatis 扫描器，逐个断言已注册
        try (GenericApplicationContext context = new GenericApplicationContext()) {
            ClassPathMapperScanner scanner = new ClassPathMapperScanner(context);
            scanner.setResourceLoader(new PathMatchingResourcePatternResolver());
            scanner.setBeanNameGenerator(new AnnotationBeanNameGenerator());
            scanner.setEnvironment(context.getEnvironment());
            scanner.registerFilters();
            scanner.scan(pattern);

            List<String> registered = Arrays.asList(context.getBeanDefinitionNames());
            for (String mapperType : mapperTypes) {
                assertThat(registered)
                        .as("%s 未被 @MapperScan(\"%s\") 注册为 bean——注入它的组件会在启动期失败",
                                mapperType, pattern)
                        .contains(beanNameOf(mapperType));
            }
        }
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
    private String packageOf(String fullyQualifiedName) {
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
    private String beanNameOf(String fullyQualifiedName) {
        String simpleName = fullyQualifiedName.substring(fullyQualifiedName.lastIndexOf('.') + 1);
        return Introspector.decapitalize(simpleName);
    }
}
