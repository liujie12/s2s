package com.s2s.server.track;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 埋点落库 SQL 形态静态守门（[129] P2b；详设 §5.8 第 [7] 步 + §9 自检清单；编码规范 §7.2-⑨）。
 *
 * <p><b>为什么必须是会失败的自动化</b>：埋点落库语句是「客户端每批换新幂等键」这一客户端规则
 * 的<b>唯一对价</b>（详设 §5.8 第 [7] 步、数据库设计 §3.16.1）。它一旦被改成
 * {@code INSERT IGNORE} 或 {@code ON DUPLICATE KEY UPDATE props = VALUES(props)}，
 * <b>表面上一切正常</b>：不报错、不去重、也不覆盖，只是数据质量悄然劣化——埋点本就是
 * 「异步旁路、允许丢」的低关注度链路，这类退化可以积累很久无人察觉。故以静态扫描钉死形态。</p>
 *
 * <p><b>判据（逐条对回依据源）</b>：</p>
 * <ol>
 *   <li>落库语句末尾必须是 {@code ON DUPLICATE KEY UPDATE id = id}（无副作用自赋值）——
 *       命中唯一索引 {@code uk_event_dedup} 即等效忽略，但不掩盖其他错误；</li>
 *   <li>严禁 {@code INSERT IGNORE}——它把数据截断、非空列插 NULL、类型转换失败一并降级为
 *       warning，等于关掉本表全部数据质量报错；</li>
 *   <li>{@code ts} 必须绑定客户端上报值 {@code #{e.ts}}，严禁 {@code NOW()} /
 *       {@code CURRENT_TIMESTAMP}——用服务端到达时刻会让重传拿到不同 {@code ts}，
 *       {@code uk_event_dedup} 当场失效且不报任何错；</li>
 *   <li>目标表名必须是占位符 {@code ${tableName}}（由 service 按
 *       {@code ^track_event_\d{6}$} 白名单复校后传入），不得写死某张月表——
 *       写死即同时废掉「按 {@code ts} 归月」与白名单校验两道防线。</li>
 * </ol>
 *
 * <p>判据抽成纯函数 {@link #judgeTrackInsertSql(List)} 并配变异自检：对每种破坏形状必须判红、
 * 对合法形状不得误报——判据本身也要被证伪。</p>
 */
class TrackSqlFormGuardTest {

    /** 埋点落库 SQL 的唯一所在（相对仓库根；测试工作目录为仓库根）。 */
    private static final Path TRACK_MAPPER_XML =
            Path.of("src", "main", "resources", "mapper", "TrackEventMapper.xml");

    /** 去重子句的归一化形态（去掉全部空白后比对，兼容 {@code id = id} / {@code id=id}）。 */
    private static final String DEDUP_CLAUSE_COMPACT = "onduplicatekeyupdateid=id";

    /** 客户端 {@code ts} 的绑定形态。 */
    private static final String CLIENT_TS_BINDING = "#{e.ts}";

    /** 表名占位符的绑定形态（service 白名单校验后传入）。 */
    private static final String TABLE_PLACEHOLDER_COMPACT = "insertinto${tablename}(";

    /** 单条 {@code <insert>} 语句体（含嵌套内容；本域 XML 无嵌套 insert）。 */
    private static final Pattern INSERT_BODY = Pattern.compile("(?s)<insert\\b[^>]*>(.*?)</insert>");

    /**
     * 埋点落库 SQL 形态合规：去重子句逐字、无 {@code INSERT IGNORE}、{@code ts} 取客户端值、
     * 表名走占位符。
     *
     * @throws IOException XML 不可读时抛出（扫描面缺失属环境缺陷，不得静默当成通过）
     */
    @Test
    @DisplayName("埋点落库 SQL：ON DUPLICATE KEY UPDATE id = id + ts 客户端值 + 表名占位符")
    void trackInsertSqlKeepsFrozenForm() throws IOException {
        List<String> bodies = insertBodies(TRACK_MAPPER_XML);
        String verdict = judgeTrackInsertSql(bodies);

        assertThat(verdict)
                .as("详设 §5.8 第 [7] 步：埋点落库形态被改动即视为缺陷（该形态是客户端换新幂等键的唯一对价）")
                .isNull();
    }

    /**
     * 变异自检：判据本身要被证伪——每种破坏形状都必须判红，合法形状不得误报。
     *
     * <p>合成 SQL 不与仓库现状耦合，只验证判别力。</p>
     *
     * @return void；断言失败即判据存在静默面（漏判 = 门禁形同虚设）
     */
    @Test
    @DisplayName("[变异自检] SQL 形态判据：该红必红、不该红不红")
    void judgementRejectsEachBrokenShape() {
        // 合法形态（等价于当前 XML）
        String legit = "INSERT INTO ${tableName} (event_name, ts) VALUES (#{e.eventName}, #{e.ts}) "
                + "ON DUPLICATE KEY UPDATE id = id";
        assertThat(judgeTrackInsertSql(List.of(legit))).isNull();

        // 破坏 1：INSERT IGNORE（静默容错一切）
        assertThat(judgeTrackInsertSql(List.of(
                "INSERT IGNORE INTO ${tableName} (ts) VALUES (#{e.ts})"))).isNotNull();
        // 破坏 2：被覆盖式去重（后到的重复批次会改写首次落库的属性）
        assertThat(judgeTrackInsertSql(List.of(
                "INSERT INTO ${tableName} (props) VALUES (#{e.propsJson}) "
                        + "ON DUPLICATE KEY UPDATE props = VALUES(props)"))).isNotNull();
        // 破坏 3：去重子句整个缺失（重传即产生重复行）
        assertThat(judgeTrackInsertSql(List.of(
                "INSERT INTO ${tableName} (ts) VALUES (#{e.ts})"))).isNotNull();
        // 破坏 4：ts 改服务端时刻（唯一键当场失效而不报错）
        assertThat(judgeTrackInsertSql(List.of(
                "INSERT INTO ${tableName} (event_name, ts) VALUES (#{e.eventName}, NOW()) "
                        + "ON DUPLICATE KEY UPDATE id = id"))).isNotNull();
        // 破坏 5：表名写死月表（按 ts 归月与白名单校验同时失效）
        assertThat(judgeTrackInsertSql(List.of(
                "INSERT INTO track_event_202609 (ts) VALUES (#{e.ts}) "
                        + "ON DUPLICATE KEY UPDATE id = id"))).isNotNull();
        // 破坏 6：扫描面为空（XML 被删或路径漂移）
        assertThat(judgeTrackInsertSql(List.of())).isNotNull();
    }

    /**
     * 判据纯函数：给定埋点落库语句体集合，返回 {@code null}（通过）或失败原因。
     *
     * <p>比对前去掉全部空白并转小写，使 {@code id = id} / {@code ID=ID} 等等价写法不被误判，
     * 同时让 {@code props = VALUES(props)} 这类同形变体无法混过。</p>
     *
     * @param insertBodies 每条 {@code <insert>} 标签内的 SQL 文本
     * @return {@link String}；{@code null} 表示全部合规
     */
    static String judgeTrackInsertSql(List<String> insertBodies) {
        if (insertBodies.isEmpty()) {
            return "未在埋点 Mapper XML 中扫到任何 <insert> 语句——扫描面为空是失真而非通过"
                    + "（埋点落库能力不应被摘除或搬家）";
        }
        for (String body : insertBodies) {
            String compact = body.replaceAll("\\s+", "").toLowerCase();
            if (compact.contains("insertignore")) {
                return "埋点落库严禁 INSERT IGNORE：它把数据截断、非空列插 NULL、类型转换失败"
                        + "一并降级为 warning（详设 §5.8 三条实现纪律之一）";
            }
            if (!compact.endsWith(DEDUP_CLAUSE_COMPACT)) {
                return "埋点落库必须以 ON DUPLICATE KEY UPDATE id = id 收尾（无副作用自赋值）；"
                        + "严禁 props = VALUES(props) 之类的覆盖式去重（会改写首次落库的事件属性）";
            }
            if (!compact.contains(CLIENT_TS_BINDING)) {
                return "埋点落库的 ts 必须绑定客户端上报值 " + CLIENT_TS_BINDING
                        + "，严禁 NOW()/CURRENT_TIMESTAMP——改用服务端时刻会让重传拿到不同 ts，"
                        + "uk_event_dedup 静默失效（数据库设计 §3.16.1）";
            }
            if (!compact.contains(TABLE_PLACEHOLDER_COMPACT)) {
                return "埋点落库目标表必须用占位符 ${tableName}（service 按 ^track_event_\\d{6}$ "
                        + "白名单复校后传入）；写死月表名会同时废掉按 ts 归月与白名单校验两道防线";
            }
        }
        return null;
    }

    /**
     * 读取 mapper XML，切出全部 {@code <insert>} 语句体的 SQL 文本。
     *
     * @param xmlPath mapper XML 路径（相对仓库根）
     * @return {@link List} 各 insert 语句体；文件缺失时抛断言失败
     * @throws IOException 文件不可读时抛出
     */
    private static List<String> insertBodies(Path xmlPath) throws IOException {
        assertThat(Files.isRegularFile(xmlPath))
                .as("埋点 Mapper XML 必须存在（%s）——不存在即扫描面失真，按失败处理", xmlPath)
                .isTrue();
        String xml = Files.readString(xmlPath, StandardCharsets.UTF_8);
        List<String> bodies = new ArrayList<>();
        Matcher matcher = INSERT_BODY.matcher(xml);
        while (matcher.find()) {
            bodies.add(matcher.group(1));
        }
        return bodies;
    }
}
