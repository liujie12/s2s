package com.s2s.server.support;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * MyBatis Mapper XML 语句提取与规范化（SQL 形态守门测试的共享骨架）。
 *
 * <p>为什么要收编成唯一实现处（编码规范 §1.1）：SQL 守门断言依赖「去 CDATA / 去 XML 实体 /
 * 去空白 / 转小写」这四个归一化步骤，任何一处少做都会让断言假红或假绿。同一个骨架抄到
 * 第二个测试类即须收编，避免口径漂移。</p>
 */
public final class MyBatisSql {

    /** 语句提取式：{@code <insert|select|update|delete id="xxx" ...>...</标签>}。 */
    private static final Pattern STATEMENT =
            Pattern.compile("(?s)<(insert|select|update|delete)\\s+id=\"([A-Za-z0-9_]+)\"[^>]*>(.*?)</\\1>");

    private MyBatisSql() {
        // 工具类，不实例化。
    }

    /**
     * 提取 Mapper XML 中全部语句（id → 规范化语句体）。
     *
     * @param xmlPath Mapper XML 路径（测试工作目录为仓库根）
     * @return {@link Map} 语句 id → 规范化语句体（保持文档顺序）
     * @throws IOException 文件不可读时抛出
     */
    public static Map<String, String> allStatements(Path xmlPath) throws IOException {
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
     * 从 Mapper XML 中按语句 id 提取语句体并规范化（去空白、转小写）。
     *
     * @param xmlPath Mapper XML 路径
     * @param id      语句 id
     * @return {@link String} 规范化后的语句体
     * @throws IOException    文件不可读时抛出
     * @throws AssertionError 语句 id 不存在时抛出（fail-closed）
     */
    public static String statement(Path xmlPath, String id) throws IOException {
        String body = allStatements(xmlPath).get(id);
        assertThat(body)
                .as("Mapper XML 中必须存在语句 id=%s（改名或删语句即判据失真，须人工确认）", id)
                .isNotNull();
        return body;
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
