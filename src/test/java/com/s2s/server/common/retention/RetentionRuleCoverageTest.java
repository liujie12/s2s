package com.s2s.server.common.retention;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 保留策略注册表 × PRD §13.4 双向比对门禁（Batch1 R17；《数据库设计文档》§5 + DevSecOps §6）。
 *
 * <p><b>为什么是构建门禁而不是人工核对</b>：R17 的原文是「注册表 key 集合须与 PRD §13.4
 * 表格第 2 列逐值相等，任一侧改动而另一侧未跟进则构建失败」。保留期是<b>合规承诺</b>
 * （审计 180 天、注销 7 天），单侧改动不会报错、不会降级，只会让系统行为与文档承诺
 * 悄悄分叉——这正是门禁要挡的形状。</p>
 *
 * <p><b>比对双方</b>：本侧 {@link RetentionRuleRegistry#keys()} ⟷ 文档侧 PRD
 * {@code ### 13.4 数据保留与删除策略} 表格的「保留策略键」列（反引号包裹的第 2 列）。</p>
 *
 * <p>判据抽成纯函数 {@link #judgeCoverage(Set, List)} 并配变异自检：漏一条、多一条、
 * 拼写不同、文档表格被清空四种形状都必须判红。</p>
 */
class RetentionRuleCoverageTest {

    /** PRD 路径（测试工作目录为仓库根）。 */
    private static final Path PRD = Path.of("docs", "PRD.md");

    /** §13.4 章节起始行（切片锚点）。 */
    private static final String SECTION_ANCHOR = "### 13.4 数据保留与删除策略";

    /** 表格数据行第 2 列（反引号包裹的保留策略键）的识别式。 */
    private static final Pattern RETENTION_KEY_CELL =
            Pattern.compile("^\\|\\s*[^|]+\\|\\s*`([a-z0-9_]+)`\\s*\\|");

    /** 期望条数：PRD §13.4 表格 9 行（条数变化即文档口径变化，须人工确认后再改本值）。 */
    private static final int EXPECTED_KEY_COUNT = 9;

    /**
     * 注册表 key 集合与 PRD §13.4 表格逐值相等。
     *
     * @throws IOException PRD 不可读时抛出（扫描面缺失属环境缺陷，不得当作通过）
     */
    @Test
    @DisplayName("RetentionRuleRegistry 的 key 集合 == PRD §13.4 保留策略键列（双向）")
    void registryMatchesPrdRetentionKeys() throws IOException {
        List<String> documented = retentionKeysInPrd(PRD);

        assertThat(documented)
                .as("PRD §13.4 表格应含 %d 条保留策略键；条数变化须人工确认后同步本门禁与注册表",
                        EXPECTED_KEY_COUNT)
                .hasSize(EXPECTED_KEY_COUNT);

        assertThat(judgeCoverage(RetentionRuleRegistry.keys(), documented))
                .as("保留策略注册表与 PRD §13.4 必须逐值相等（R17：任一侧改动另一侧须回应）")
                .isNull();

        // 每条策略都须声明执行者，不允许空值（空值等于「这条没人执行」，即架构 §8 禁止的形态）
        assertThat(RetentionRuleRegistry.rules())
                .allSatisfy((key, executor) -> assertThat(executor)
                        .as("保留策略 %s 必须声明执行者", key)
                        .isNotBlank());
    }

    /**
     * 变异自检：判据本身要被证伪——漏、多、拼写不同、文档空表四种形状必红，一致时不得误报。
     *
     * @return void；断言失败即判据存在静默面（漏判 = 门禁形同虚设）
     */
    @Test
    @DisplayName("[变异自检] 双向比对判据：该红必红、不该红不红")
    void judgementRejectsEachBrokenShape() {
        Set<String> registry = Set.of("audit_log_180d", "deactivate_7d");
        List<String> doc = List.of("audit_log_180d", "deactivate_7d");

        assertThat(judgeCoverage(registry, doc)).isNull();

        // 漏一条（注册表少登记）
        assertThat(judgeCoverage(Set.of("audit_log_180d"), doc)).isNotNull();
        // 多一条（注册表自造键）
        assertThat(judgeCoverage(Set.of("audit_log_180d", "deactivate_7d", "brand_new_30d"), doc))
                .isNotNull();
        // 拼写不同（大小写/下划线差异，必须判红——「看起来一样」正是最危险的分叉）
        assertThat(judgeCoverage(Set.of("audit_log_180D", "deactivate_7d"), doc)).isNotNull();
        // 文档侧为空（切片锚点失效或表格被删，属扫描面失真）
        assertThat(judgeCoverage(registry, List.of())).isNotNull();
    }

    /**
     * 判据纯函数：注册表 key 集合与文档解析出的 key 列表双向比对。
     *
     * @param registryKeys 注册表登记的保留策略键
     * @param documentedKeys PRD §13.4 表格解析出的保留策略键（按出现顺序）
     * @return {@link String}；{@code null} 表示两侧逐值相等
     */
    static String judgeCoverage(Set<String> registryKeys, List<String> documentedKeys) {
        if (documentedKeys.isEmpty()) {
            return "PRD §13.4 未解析出任何保留策略键——切片锚点失效或表格被删，空扫描面是失真而非通过";
        }
        Set<String> docSet = new LinkedHashSet<>(documentedKeys);
        Set<String> missingInRegistry = new LinkedHashSet<>(docSet);
        missingInRegistry.removeAll(registryKeys);
        Set<String> extraInRegistry = new LinkedHashSet<>(registryKeys);
        extraInRegistry.removeAll(docSet);
        if (!missingInRegistry.isEmpty() || !extraInRegistry.isEmpty()) {
            return "注册表与 PRD §13.4 不一致：注册表缺 " + missingInRegistry
                    + "，注册表多 " + extraInRegistry;
        }
        return null;
    }

    /**
     * 解析 PRD §13.4 章节表格的「保留策略键」列。
     *
     * <p>只在该章节切片内匹配（从章节标题到下一个 {@code ---} 分隔线），避免把全文其它
     * 反引号短语误当作策略键。</p>
     *
     * @param prd PRD 文件路径
     * @return {@link List} 保留策略键（按表格出现顺序；重复项保留以便暴露文档笔误）
     * @throws IOException 文件不可读时抛出
     */
    private static List<String> retentionKeysInPrd(Path prd) throws IOException {
        assertThat(Files.isRegularFile(prd))
                .as("PRD 必须存在（%s）——不存在即比对面失真", prd)
                .isTrue();
        String content = Files.readString(prd, StandardCharsets.UTF_8);
        int start = content.indexOf(SECTION_ANCHOR);
        assertThat(start)
                .as("PRD 中必须存在 %s 章节（R17 的比对锚点）", SECTION_ANCHOR)
                .isGreaterThanOrEqualTo(0);
        int end = content.indexOf("\n---", start);
        String section = end < 0 ? content.substring(start) : content.substring(start, end);

        List<String> keys = new ArrayList<>();
        for (String line : section.split("\n")) {
            Matcher matcher = RETENTION_KEY_CELL.matcher(line);
            if (matcher.find()) {
                keys.add(matcher.group(1));
            }
        }
        return keys;
    }

    /**
     * 断言注册表本身自洽（供人工排查时快速定位：键重复/为空）。
     *
     * @return void；断言失败即注册表结构异常
     */
    @Test
    @DisplayName("注册表自洽：键非空、无重复、执行者说明齐备")
    void registryIsSelfConsistent() {
        Map<String, String> rules = RetentionRuleRegistry.rules();
        assertThat(rules).hasSize(EXPECTED_KEY_COUNT);
        assertThat(rules.keySet()).allSatisfy(key -> assertThat(key).isNotBlank());
    }
}
