package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 定时任务 SQL 形态静态守门（[129] P4；编码规范 §7.2-⑧「任务 #1 守 status / #3 用 DROP /
 * #7 按 user_id 全删」；详设 §6 + §9 自检清单）。
 *
 * <p><b>为什么这三条必须是会失败的自动化</b>：它们都属于「改错了不报错、只在很久以后以
 * 事故形态出现」的形态约定——</p>
 * <ol>
 *   <li><b>#1 守 status 不守 version</b>：若被改成守 version，定时任务不持有用户视图的
 *       version，会被用户的并发编辑饿死，表现为「帖子到期却一直不下架」，无任何错误日志；</li>
 *   <li><b>#3 用 DROP 不用 DELETE</b>：逐行 DELETE 千万行月表会把 buffer pool 与 binlog
 *       一起打满（数据库设计 §6.5），而这在开发库的小数据量下完全看不出来；</li>
 *   <li><b>#7 按 user_id 全删</b>：若被改成按身份行 id 删，会只删掉一行；Batch2 起同一账号
 *       挂多行身份（如 wechat），残留身份可登录、注销承诺失效——而这在 Batch1 只有 phone
 *       一行时<b>测不出来</b>。</li>
 * </ol>
 *
 * <p>判据为对 Mapper XML 的语句体做规范化（去空白、转小写）后的子串断言；
 * 语句按 {@code id} 精确提取，与语句顺序无关。</p>
 */
class TaskSqlGuardTest {

    /** 业务库任务 Mapper XML（测试工作目录为仓库根）。 */
    private static final Path TASK_MAPPER_XML =
            Path.of("src", "main", "resources", "mapper", "TaskMapper.xml");

    /** 埋点库维护 Mapper XML。 */
    private static final Path TRACK_MAINTENANCE_XML =
            Path.of("src", "main", "resources", "mapper", "TrackMaintenanceMapper.xml");

    /** 语句提取式：{@code <insert|select|update|delete id="xxx" ...>...</标签>}。 */
    private static final Pattern STATEMENT =
            Pattern.compile("(?s)<(insert|select|update|delete)\\s+id=\"([A-Za-z0-9_]+)\"[^>]*>(.*?)</\\1>");

    /**
     * #1 到期下架：必须守 {@code status = 'active'}，且不得出现 {@code version} 条件。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("#1 到期下架：守 status='active' 且不守 version（详设 §5.3.3 写守卫分流）")
    void archiveExpiredPostsGuardsStatusNotVersion() throws IOException {
        String sql = statement(TASK_MAPPER_XML, "archiveExpiredPosts");

        assertThat(sql).contains("status='active'");
        assertThat(sql)
                .as("系统派生变更必须不守 version，否则被用户并发编辑饿死（详设 §5.3.3）")
                .doesNotContain("version");
        assertThat(sql)
                .as("到期自动下架的库内归因固定为 status_reason=1（PostStatus 派生 expired 的依据）")
                .contains("status_reason=1");
        assertThat(sql).contains("expire_at<=#{now}");
    }

    /**
     * #3 埋点月表清理：必须是 {@code DROP TABLE}，且埋点维护 Mapper 内不得出现任何 {@code DELETE}。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("#3 月表清理：整表 DROP，且维护 Mapper 内无 DELETE（数据库设计 §6.5）")
    void monthTableCleanupUsesDropNotDelete() throws IOException {
        String sql = statement(TRACK_MAINTENANCE_XML, "dropTable");
        assertThat(sql).contains("droptableifexists");

        assertThat(allStatements(TRACK_MAINTENANCE_XML).values())
                .as("埋点库维护语句中不得出现 DELETE——逐行删除千万行表会打满 buffer pool 与 binlog")
                .allSatisfy(body -> assertThat(body).doesNotContain("delete"));
    }

    /**
     * #2 月表预建：必须是 {@code CREATE TABLE ... LIKE}（连索引一起复制，否则下月去重静默失效）。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("#2 月表预建：用 CREATE TABLE ... LIKE（否则漏掉 uk_event_dedup，去重静默失效）")
    void monthTablePrebuildCopiesIndexes() throws IOException {
        String sql = statement(TRACK_MAINTENANCE_XML, "createTableLike");
        assertThat(sql).contains("createtableifnotexists");
        assertThat(sql)
                .as("必须 LIKE 复制结构（含唯一索引）；逐列拼 DDL 会漏 uk_event_dedup")
                .contains("like");
    }

    /**
     * #7 注销清理：按 {@code user_id} 删除全部身份行（不是按身份行 id 删一行）。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("#7 注销清理：DELETE FROM user_identity WHERE user_id IN（不是按 id 删一行）")
    void deactivateCleanupDeletesIdentitiesByUserId() throws IOException {
        String identities = statement(TASK_MAPPER_XML, "deleteIdentitiesByUserIds");
        assertThat(identities).contains("deletefromuser_identity");
        assertThat(identities)
                .as("必须按 user_id 批量删（Batch2 起同一账号挂多行身份，残留身份会复活账号）")
                .contains("whereuser_idin");

        String personalData = statement(TASK_MAPPER_XML, "clearUserPersonalData");
        assertThat(personalData)
                .as("实名结果三列必须清空（合规义务，不可省略）")
                .contains("real_name_enc=null")
                .contains("id_card_hash=null")
                .contains("id_card_last4=null");
        assertThat(personalData)
                .as("phone_mask 为 NOT NULL 列，置空串而非 NULL")
                .contains("phone_mask=''");

        assertThat(statement(TASK_MAPPER_XML, "deletePostsByUserIds"))
                .as("第 4 步（用户 2026-09-29 裁定「连帖子一并删除」）：按 user_id 删帖，"
                        + "使 contact_value_enc 不再随帖留存")
                .contains("deletefrompost")
                .contains("whereuser_idin");
    }

    /**
     * 清理类语句必须按时间列过滤（否则会删全表），且孤儿媒体判定必须为 {@code post_id IS NULL}。
     *
     * @throws IOException XML 不可读时抛出
     */
    @Test
    @DisplayName("清理语句的时间过滤与孤儿判定条件齐备")
    void cleanupStatementsFilterByTimeColumn() throws IOException {
        assertThat(statement(TASK_MAPPER_XML, "deleteAuditLogsBefore"))
                .contains("created_at<#{threshold}");
        assertThat(statement(TASK_MAPPER_XML, "deleteFavoritesBefore"))
                .contains("deleted_atisnotnull")
                .contains("deleted_at<#{threshold}");
        assertThat(statement(TASK_MAPPER_XML, "selectPendingMedia"))
                .as("孤儿判定 = 从未 commit（post_id 空）+ 仍待审（pending）")
                .contains("audit_status='pending'")
                .contains("post_idisnull")
                .contains("created_at<#{threshold}");
        assertThat(statement(TASK_MAPPER_XML, "selectDeactivatingUserIds"))
                .as("非空即未撤回；撤回会清空 deactivate_at（PRD §9.7「撤回后数据原封不动」）")
                .contains("deactivate_atisnotnull");
    }

    /**
     * 从 Mapper XML 中按语句 id 提取语句体并规范化（去空白、转小写）。
     *
     * @param xmlPath Mapper XML 路径
     * @param id      语句 id
     * @return {@link String} 规范化后的语句体
     * @throws IOException           文件不可读时抛出
     * @throws AssertionError        文件缺失或语句 id 不存在时抛出（fail-closed）
     */
    private static String statement(Path xmlPath, String id) throws IOException {
        String body = allStatements(xmlPath).get(id);
        assertThat(body)
                .as("Mapper XML 中必须存在语句 id=%s（改名或删语句即判据失真，须人工确认）", id)
                .isNotNull();
        return body;
    }

    /**
     * 提取 Mapper XML 中全部语句（id → 规范化语句体）。
     *
     * @param xmlPath Mapper XML 路径
     * @return {@link Map} 语句 id → 规范化语句体（保持文档顺序）
     * @throws IOException 文件不可读时抛出
     */
    private static Map<String, String> allStatements(Path xmlPath) throws IOException {
        assertThat(Files.isRegularFile(xmlPath))
                .as("Mapper XML 必须存在（%s）——不存在即判据失真", xmlPath)
                .isTrue();
        Map<String, String> statements = new LinkedHashMap<>();
        Matcher matcher = STATEMENT.matcher(Files.readString(xmlPath, StandardCharsets.UTF_8));
        while (matcher.find()) {
            statements.put(matcher.group(2), normalized(matcher.group(3)));
        }
        assertThat(statements)
                .as("未从 %s 提取到任何语句——扫描面为空是失真而非通过", xmlPath)
                .isNotEmpty();
        return statements;
    }

    /**
     * 规范化：去 CDATA 包裹与 XML 实体、去空白、转小写。
     *
     * <p>去 CDATA/实体是必要的：MyBatis XML 里 {@code <=} 只能写成 {@code <![CDATA[ <= ]]>}
     * 或 {@code &lt;=}，若不做等价还原，所有含比较符的断言都会假红/假绿。</p>
     *
     * @param text 原文
     * @return {@link String} 规范化文本
     */
    private static String normalized(String text) {
        return text.replace("<![CDATA[", "")
                .replace("]]>", "")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&amp;", "&")
                .replaceAll("\\s+", "")
                .toLowerCase();
    }
}
