package com.s2s.server.map;

import static com.s2s.server.support.MyBatisSql.allStatements;
import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 地图取 Pin 与列表检索的 SQL 形态静态守门（DEF-12）。
 *
 * <p><b>为什么这条必须是会失败的自动化</b>：V37 的软删语义是「只置 {@code deleted_at}，
 * 原 {@code status} 不变」，而 {@code /map/pins}、{@code /posts/search} 原先只按
 * {@code status = 'active'} 过滤。两者在「active + 已删除」组合下不一致，错法不抛异常、
 * 只表现为已删帖仍出现在地图与列表里；而 API 路径当前不可达（删除接口要求先下架），
 * 联调与手测都发现不了，只能靠静态守门。</p>
 *
 * <p>同时守住覆盖索引纪律：{@code deleted_at IS NULL} 必须落在
 * {@code idx_pins_cover} / {@code idx_pins_community} 内，否则 index-only scan 退化为回表
 * （V18 头部纪律：查询列集合不得增删）。</p>
 */
class MapPostSqlGuardTest {

    /** 地图 Mapper XML（测试工作目录为仓库根）。 */
    private static final Path MAP_POST_XML =
            Path.of("src", "main", "resources", "mapper", "MapPostMapper.xml");

    /** 覆盖索引迁移（V39，为 deleted_at 扩索引）。 */
    private static final Path V39_MIGRATION =
            Path.of("src", "main", "resources", "db", "migration", "V39__pins_deleted_index.sql");

    /** 必须带软删过滤的四条语句（pins 聚合 / 计数 / 聚簇 / 列表检索）。 */
    private static final List<String> GUARDED_STATEMENTS =
            List.of("selectPins", "countPins", "selectClusters", "selectSearchPosts");

    /**
     * 四条读路径都必须排除软删帖。
     *
     * <p>规范化后的小写文本里，别名与非别名写法统一呈现为 {@code deleted_atisnull}，
     * 故同一断言可覆盖 {@code deleted_at}（post）与 {@code p.deleted_at}（JOIN 版）。</p>
     *
     * @throws IOException Mapper XML 不可读时抛出
     */
    @Test
    @DisplayName("pins/clusters/search：四条读路径均带 deleted_at IS NULL")
    void mapReadPathsExcludeSoftDeletedPosts() throws IOException {
        Map<String, String> statements = allStatements(MAP_POST_XML);

        for (String id : GUARDED_STATEMENTS) {
            String sql = statements.get(id);
            assertThat(sql)
                    .as("语句 %s 必须存在（改名或删语句即判据失真）", id)
                    .isNotNull();
            assertThat(sql)
                    .as("%s 只按 status 过滤会漏掉「active + 已删除」（V37 软删不改 status）", id)
                    .contains("status='active'")
                    .contains("deleted_atisnull");
        }
    }

    /**
     * 覆盖索引必须纳入 deleted_at，且两个索引列序一致（紧随 price 之后）。
     *
     * @throws IOException 迁移文件不可读时抛出
     */
    @Test
    @DisplayName("V39：idx_pins_cover / idx_pins_community 均含 deleted_at")
    void coveringIndexesIncludeDeletedAt() throws IOException {
        assertThat(Files.isRegularFile(V39_MIGRATION))
                .as("V39 迁移必须存在——否则 WHERE 新增 deleted_at 会使覆盖索引退化为回表")
                .isTrue();
        String sql = Files.readString(V39_MIGRATION, StandardCharsets.UTF_8);

        assertThat(sql).contains("idx_pins_cover").contains("idx_pins_community");

        Matcher matcher = Pattern.compile("`deleted_at`,\\s*`id`").matcher(sql);
        int hits = 0;
        while (matcher.find()) {
            hits++;
        }
        assertThat(hits)
                .as("两个覆盖索引都必须把 deleted_at 放在响应列 id 之前（实得 %d 处）", hits)
                .isEqualTo(2);
    }
}
