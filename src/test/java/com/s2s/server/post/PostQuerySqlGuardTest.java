package com.s2s.server.post;

import static com.s2s.server.support.MyBatisSql.statement;
import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Path;
import java.util.regex.Pattern;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 收藏与浏览计数的 SQL 形态静态守门（U8；KTD6 / KTD7 / KTD11）。
 *
 * <p><b>为什么这几条必须是会失败的自动化</b>：它们的错法都不抛异常，只在数据上表现为
 * 「数字慢慢不对」，靠联调几乎发现不了——</p>
 * <ol>
 *   <li>收藏聚合漏 {@code deleted_at IS NULL}：用户取消过的收藏仍被计数，且随取消次数
 *       越滚越多；</li>
 *   <li>收藏聚合漏 {@code user_id <> 作者}：作者自收藏被算作对外反馈（用户裁定排除）；</li>
 *   <li>浏览聚合读了明细表 {@code post_view}：明细按保留期清理后计数会「倒退」（KTD7）；</li>
 *   <li>日计数用 {@code INSERT IGNORE}：唯一键冲突被静默降级为 0 行，无法区分
 *       「已去过重」与「写失败」（KTD6）；</li>
 *   <li>明细清理误伤 {@code post_view_daily}：累计计数被删（KTD7 明确日计数永久保留）。</li>
 * </ol>
 */
class PostQuerySqlGuardTest {

    /** 帖主视角聚合 Mapper XML（测试工作目录为仓库根）。 */
    private static final Path POST_QUERY_XML =
            Path.of("src", "main", "resources", "mapper", "PostQueryMapper.xml");

    /** 收藏 Mapper XML。 */
    private static final Path FAVORITE_XML =
            Path.of("src", "main", "resources", "mapper", "FavoriteMapper.xml");

    /** 浏览 Mapper XML。 */
    private static final Path POST_VIEW_XML =
            Path.of("src", "main", "resources", "mapper", "PostViewMapper.xml");

    /** 定时任务 Mapper XML。 */
    private static final Path TASK_XML =
            Path.of("src", "main", "resources", "mapper", "TaskMapper.xml");

    /**
     * 收藏数聚合：必须排除软删行与作者本人（KTD11）。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("收藏聚合：deleted_at IS NULL 且 user_id <> 作者")
    void favoriteAggregationExcludesDeletedAndAuthor() throws IOException {
        String sql = statement(POST_QUERY_XML, "countFavoritesByPost");

        assertThat(sql).contains("fromfavorite");
        assertThat(sql)
                .as("漏掉软删过滤会把取消过的收藏继续计数")
                .contains("deleted_atisnull");
        assertThat(sql)
                .as("作者自收藏不得计入对外反馈（用户 2026-10-27 裁定）")
                .contains("user_id<>#{ownerid}");
        assertThat(sql)
                .as("整页一次聚合，禁止逐帖查询")
                .contains("groupbypost_id");
    }

    /**
     * 浏览数聚合：只读日计数表，不得读明细表（KTD7）。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("浏览聚合：SUM(post_view_daily)，不读 post_view 明细")
    void viewAggregationReadsDailyTableOnly() throws IOException {
        String sql = statement(POST_QUERY_XML, "sumPostViews");

        assertThat(sql).contains("frompost_view_daily");
        assertThat(sql).contains("sum(view_count)");
        assertThat(sql).contains("groupbypost_id");
        assertThat(Pattern.compile("frompost_view(?!_daily)").matcher(sql).find())
                .as("浏览数只能来自日计数表；读明细表会在保留期清理后倒退（KTD7）")
                .isFalse();
    }

    /**
     * 详情收藏态：只算未软删的收藏。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("详情收藏态：只认 deleted_at IS NULL 的有效收藏")
    void activeFavoriteCountExcludesDeleted() throws IOException {
        String sql = statement(FAVORITE_XML, "countActiveFavorite");

        assertThat(sql).contains("fromfavorite");
        assertThat(sql).contains("deleted_atisnull");
        assertThat(sql)
                .as("收藏态必须按当前用户 + 帖子定位，不能只按 post_id")
                .contains("user_id=#{userid}")
                .contains("post_id=#{postid}");
    }

    /**
     * 日计数写入：{@code ON DUPLICATE KEY UPDATE} + {@code GREATEST(0, ...)}（KTD6）。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("日计数写入：ON DUPLICATE KEY UPDATE，不用 INSERT IGNORE")
    void dailyUpsertAccumulatesInsteadOfIgnoring() throws IOException {
        String sql = statement(POST_VIEW_XML, "upsertDaily");

        assertThat(sql).contains("onduplicatekeyupdate");
        assertThat(sql)
                .as("INSERT IGNORE 会把冲突静默降级为 0 行，无法区分「已去过重」与「写失败」")
                .doesNotContain("insertignore");
        assertThat(sql)
                .as("合并当日设备行会传负 delta，必须钳到 0 防负数")
                .contains("greatest(0,");
        assertThat(sql)
                .as("无符号列不得直接写 delta：INSERT 分支在唯一键判重前做值域校验，-1 会 50001")
                .contains("values(#{postid},#{viewday},greatest(0,#{delta}))");
        assertThat(sql)
                .as("UPDATE 分支的无符号加法须先 CAST SIGNED，否则 view_count + -1 溢出")
                .contains("cast(view_countassigned)");
    }

    /**
     * 明细清理：只删 {@code post_view}，且按 view_day 过滤 + 限量分批。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("明细清理：只删 post_view，日计数表永不参与清理（KTD7）")
    void detailCleanupNeverTouchesDailyTable() throws IOException {
        String sql = statement(TASK_XML, "deletePostViewsBefore");

        assertThat(sql).contains("deletefrompost_view");
        assertThat(sql).contains("view_day<#{threshold}");
        assertThat(sql)
                .as("分批删除：单次全量删除会打满 binlog")
                .contains("limit#{limit}");
        assertThat(sql)
                .as("日计数永久保留，清理语句不得出现 post_view_daily")
                .doesNotContain("post_view_daily");
    }
}
