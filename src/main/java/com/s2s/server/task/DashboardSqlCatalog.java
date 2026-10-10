package com.s2s.server.task;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 主看板 SQL 清单解析器（[148]；《可观测性架构方案》§9.1.1）。
 *
 * <p><b>为什么要有这一层</b>：T3 的判定对象是已交付的<b>单一文件</b>
 * {@code docs/architecture/dashboard_queries.sql}——「清单即判定对象」。把七条 SQL 抄成
 * 常量或固定 XML 语句，就丢掉了「文件改了、判定跟着改」这条唯一对价。故任务运行期读取该文件，
 * 由本类把它切成条目：可执行的给出语句文本，不可执行的给出 N/A 原因。</p>
 *
 * <p><b>切分口径</b>：条目以标题行 {@code -- Q<编号> · …} 起止（文件头状态表用的是
 * {@code --   Q1   | …}，不含 {@code ·}，故不会误切）。条目体内的 {@code --} 注释（整行注释
 * 与行尾注释）一律剥除——Q1 的示例 SQL 就是整段注释，若不清掉会被当成可执行语句。</p>
 *
 * <p><b>可执行判据</b>：条目体内剥注释后仍有 SQL 文本即为可执行；否则按标题里的标记判定
 * N/A 原因（{@code Batch2 交付物} / {@code 非 SQL 判据}），<b>不得一律记 SKIP</b>——三种
 * 「不参与」必须可区分（同「扫描面为空是 SKIP 不是 PASS」的如实纪律）。</p>
 *
 * <p>纯函数、无状态：输入文件全文，输出条目列表；不读文件、不碰数据库（读文件由任务侧负责）。</p>
 */
final class DashboardSqlCatalog {

    /** 条目标题行：{@code -- Q<编号> · …}（{@code ·} 是与文件头状态表区分的唯一特征）。 */
    private static final Pattern HEADING = Pattern.compile("^--\\s*Q(\\d+)\\s*·.*$");

    /** N/A 原因标记：Batch2 交付物（Batch1 不参与 T3）。 */
    private static final String BATCH2_MARKER = "Batch2 交付物";

    /** N/A 原因标记：非 SQL 判据（日志扫描）。 */
    private static final String NON_SQL_MARKER = "非 SQL 判据";

    /** 条目列表（按文件出现顺序）。 */
    private final List<Query> queries;

    /**
     * 私有构造器：实例一律经 {@link #parse(String)} 产出。
     *
     * @param queries 解析结果条目列表
     */
    private DashboardSqlCatalog(List<Query> queries) {
        this.queries = List.copyOf(queries);
    }

    /**
     * 解析主看板 SQL 清单全文。
     *
     * @param content 文件全文（UTF-8）
     * @return {@link DashboardSqlCatalog} 解析结果（未解析出任何条目时为空目录）
     */
    static DashboardSqlCatalog parse(String content) {
        List<Query> result = new ArrayList<>();
        Integer currentNumber = null;
        StringBuilder statement = new StringBuilder();
        StringBuilder section = new StringBuilder();

        for (String line : content.split("\\R", -1)) {
            Matcher heading = HEADING.matcher(line);
            if (heading.matches()) {
                if (currentNumber != null) {
                    result.add(build(currentNumber, statement.toString(), section.toString()));
                }
                currentNumber = Integer.valueOf(heading.group(1));
                statement.setLength(0);
                section.setLength(0);
                section.append(line);
                continue;
            }
            if (currentNumber == null) {
                // 文件头说明区（状态表等）不属于任何条目
                continue;
            }
            section.append('\n').append(line);
            String code = stripLineComment(line).strip();
            if (!code.isEmpty()) {
                statement.append(code).append('\n');
            }
        }
        if (currentNumber != null) {
            result.add(build(currentNumber, statement.toString(), section.toString()));
        }
        return new DashboardSqlCatalog(result);
    }

    /**
     * 取解析出的条目列表。
     *
     * @return {@link List} 条目（按文件顺序；可能为空）
     */
    List<Query> queries() {
        return queries;
    }

    /**
     * 由条目原文构造一条条目（判定可执行性并给出 N/A 原因）。
     *
     * @param number      条目编号（Q 后的数字）
     * @param sqlText     条目体内剥注释后的 SQL 文本（可能为空）
     * @param sectionText 条目全文（标题行 + 正文，用于识别 N/A 原因）
     * @return {@link Query} 条目
     */
    private static Query build(int number, String sqlText, String sectionText) {
        String statement = sqlText.strip();
        if (statement.isEmpty()) {
            return new Query(number, null, naReason(sectionText));
        }
        if (statement.endsWith(";")) {
            // 单条语句不需要结尾分号；留着会让「仅允许单条 SELECT」的兜底判据误判
            statement = statement.substring(0, statement.length() - 1).stripTrailing();
        }
        return new Query(number, statement, null);
    }

    /**
     * 由条目全文推断 N/A 原因（仅在条目不可执行时调用）。
     *
     * @param sectionText 条目全文
     * @return {@link String} N/A 原因标签；无法识别标记时返回通用原因
     */
    private static String naReason(String sectionText) {
        if (sectionText.contains(BATCH2_MARKER)) {
            return "N/A（Batch2 交付物，Batch1 不参与 T3）";
        }
        if (sectionText.contains(NON_SQL_MARKER)) {
            return "N/A（非 SQL 判据，改由日志扫描执行）";
        }
        return "N/A（无判定对象）";
    }

    /**
     * 剥除一行里的 {@code --} 注释（整行注释返回空串；行尾注释返回其前半段）。
     *
     * <p>以单引号配对判断是否在字符串字面量内：{@code '--'} 不会被误当注释起点；
     * SQL 的双写转义 {@code ''} 会两次翻转状态、净效果不变，故无需特判。</p>
     *
     * @param line 原始行
     * @return {@link String} 去掉注释后的内容（保留原缩进）
     */
    private static String stripLineComment(String line) {
        boolean inQuote = false;
        for (int i = 0; i < line.length() - 1; i++) {
            char current = line.charAt(i);
            if (current == '\'') {
                inQuote = !inQuote;
            } else if (!inQuote && current == '-' && line.charAt(i + 1) == '-') {
                return line.substring(0, i);
            }
        }
        return line;
    }

    /**
     * 主看板条目。
     *
     * @param number    条目编号（Q 后的数字）
     * @param statement 可执行语句（已去注释与尾分号）；不可执行时为 {@code null}
     * @param naReason  N/A 原因标签；可执行时为 {@code null}
     */
    record Query(int number, String statement, String naReason) {
    }
}
