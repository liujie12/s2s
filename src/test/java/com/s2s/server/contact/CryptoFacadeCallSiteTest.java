package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

/**
 * 解密调用点静态守门测试（[128]；详设 §4.3、§9 自检清单第 9 项；编码规范 §7.2-⑤）。
 *
 * <p><b>为什么必须是一条会失败的自动化而不是评审时记得查</b>：详设 §4.3 把
 * 「全系统只有 {@code common.crypto.CryptoFacade} 一处可以解密」定为架构不变量——
 * Batch1 的解密调用点<b>只有一个</b>（{@code contact.ContactService#viewContact}），
 * 任何新增调用点都视为架构变更须评审。这条不变量一旦被悄悄破坏（如日后有人
 * 在图谱/调试接口里顺手解一次），它不会报错、不会降级、也不会被日志发现，
 * 只会在某天变成一次批量泄露。</p>
 *
 * <p><b>判据形态</b>：扫描 {@code src/main/java} 全部源文件，统计
 * <b>{@code .decrypt(} 的出现次数 == 1</b>。选 {@code .decrypt(} 而非
 * {@code CryptoFacade.decrypt} 是因为前者同时覆盖「经变量名调用」
 * （{@code cryptoFacade.decrypt(...)}）这一最常见形态，而后者只匹配按类名静态调用的写法。</p>
 *
 * <p>注释里出现 {@code .decrypt(} 也会计入（刻意不剥离注释）：宁可让加注释的人
 * 换个写法，也不给「真调用藏在注释判定漏洞里」留口子——fail-closed 优先。</p>
 *
 * <p><b>[128] 代码评审 #5 后的判据收紧（三处）</b>：</p>
 * <ol>
 *   <li><b>包路径而非文件名后缀</b>：原先判 {@code endsWith("ContactService.java")}，
 *       任何包下同名文件都能顶替；现判相对路径逐字等于 {@link #ONLY_ALLOWED_FILE}。</li>
 *   <li><b>同方法内必须写审计</b>：详设 §4.3 的另一半不变量是「每次解密必须与
 *       {@code audit_log} 写在<b>同一事务方法</b>内」（解密成功但留痕失败 = 一次无记录的
 *       个人信息访问）。原判据只数调用点，把调用点在同一文件内换位（删掉原调用、
 *       在另一个方法里加一处）仍全绿；现追加「命中点所在方法体内出现
 *       {@code auditLogWriter.write}」。</li>
 *   <li><b>判据抽成纯函数 + 变异自检</b>：{@link #judgeCallSites(List)} /
 *       {@link #enclosingMethod(String, int)} 均为静态纯函数，用合成源码对
 *       0 处 / 2 处 / 错包名 / 同文件换位（审计写挪到别的方法）逐个验证「该红必红」，
 *       并对合法输入验证「不该红不红」——判据本身也要被证伪，不能只靠它绿。</li>
 * </ol>
 */
class CryptoFacadeCallSiteTest {

    /** 被守门的调用形态。 */
    private static final String DECRYPT_CALL = ".decrypt(";

    /** 与解密同方法出现的审计写入（{@code AuditLogWriter#write} 的调用形态）。 */
    private static final String AUDIT_WRITE = "auditLogWriter.write";

    /** 唯一允许的调用点所在文件（相对 {@code src/main/java} 的包路径，逐字相等）。 */
    private static final String ONLY_ALLOWED_FILE = "com/s2s/server/contact/ContactService.java";

    /**
     * 方法声明行识别式：4 空格缩进 + 访问修饰符 + 同一行内出现 {@code (}。
     *
     * <p>要求 {@code (} 是为了排除同缩进的字段声明（{@code private final X a;}）——
     * 字段没有参数表，被误认为方法声明会让「所在方法体」取到下一个块。</p>
     */
    private static final Pattern METHOD_DECL =
            Pattern.compile("(?m)^ {4}(?:public|private|protected)[^;\\n=]*\\(");

    /**
     * 全库解密调用点必须<b>恰有 1 处</b>、落在指定文件、且其所在方法内写审计。
     *
     * @throws IOException 源码目录不可读时抛出（扫描面缺失属测试环境缺陷，
     *         不能静默当成通过——「扫描面为空是 SKIP 不是 PASS」）
     */
    @Test
    void decryptCallSiteIsSingleAndAudited() throws IOException {
        List<CallSite> hits = scanDecryptCalls();
        String verdict = judgeCallSites(hits);

        assertThat(verdict)
                .as("详设 §4.3：解密调用点唯一 + 与 audit_log 同方法（新增即架构变更须评审）")
                .isNull();
    }

    /**
     * 变异自检：判据本身要被证伪——对每种破坏形状都必须判红，对合法形状不得误报。
     *
     * <p>合成源码不使用真实文件，故本测试与仓库现状无关，只验证判据的判别力。</p>
     *
     * @return void；断言失败即判据存在静默面（漏判 = 门禁形同虚设）
     */
    @Test
    void judgementRejectsEachBrokenShape() {
        CallSite legit = new CallSite(ONLY_ALLOWED_FILE,
                "    public void viewContact() {\n"
                        + "        cryptoFacade.decrypt(cipher, aad, 1);\n"
                        + "        auditLogWriter.write(entry);\n"
                        + "    }\n");

        // 合法输入不得误报（否则门禁会被当成噪音而遭放宽）
        assertThat(judgeCallSites(List.of(legit))).isNull();

        // 0 处：解密能力被整体摘除也是形态变更，须人工确认
        assertThat(judgeCallSites(List.of())).isNotNull();

        // 2 处：新增调用点（详设 §4.3 的头号禁止项）
        assertThat(judgeCallSites(List.of(legit, legit))).isNotNull();

        // 命中合法文件但无审计写：解密成功却不留痕
        assertThat(judgeCallSites(List.of(new CallSite(ONLY_ALLOWED_FILE,
                "    public void viewContact() {\n"
                        + "        cryptoFacade.decrypt(cipher, aad, 1);\n"
                        + "    }\n")))).isNotNull();

        // 包路径不符：同名文件顶替
        assertThat(judgeCallSites(List.of(new CallSite("com/s2s/server/post/ContactService.java",
                legit.enclosingMethod())))).isNotNull();
    }

    /**
     * 变异自检：{@link #enclosingMethod(String, int)} 必须真的按方法边界切分——
     * 既不能切出整文件（那会让「同方法」判据永真），也不能切不出（永假）。
     *
     * @return void；断言失败即结构性判据失效
     */
    @Test
    void enclosingMethodStopsAtMethodBoundary() {
        // 审计写在**另一个方法**里 —— 即代码评审 #5 点名的「同文件换位绕过」
        String movedAudit = "class A {\n"
                + "    private void viewContact() {\n"
                + "        cryptoFacade.decrypt(x);\n"
                + "    }\n"
                + "    private void elsewhere() {\n"
                + "        auditLogWriter.write(e);\n"
                + "    }\n"
                + "}\n";
        assertThat(enclosingMethod(movedAudit, movedAudit.indexOf(DECRYPT_CALL)))
                .as("审计写被挪到别的方法时，所在方法体内不得看见它")
                .doesNotContain(AUDIT_WRITE);

        // 同一方法内 —— 必须看见，且不含方法之后的其它成员
        String sameMethod = "class A {\n"
                + "    private void viewContact() {\n"
                + "        cryptoFacade.decrypt(x);\n"
                + "        auditLogWriter.write(e);\n"
                + "    }\n"
                + "    private void elsewhere() {\n"
                + "        auditLogWriter.write(e);\n"
                + "    }\n"
                + "}\n";
        String body = enclosingMethod(sameMethod, sameMethod.indexOf(DECRYPT_CALL));
        assertThat(body).contains(AUDIT_WRITE).contains(DECRYPT_CALL);
        assertThat(countOf(body, AUDIT_WRITE))
                .as("方法体须在方法边界处截断，不得延伸到下一个方法")
                .isEqualTo(1);

        // 定位失败按空串处理（判为上抛失败，不静默放行）
        assertThat(enclosingMethod("no method here", 3)).isEmpty();
    }

    /**
     * 扫描 {@code src/main/java} 下的全部解密调用点。
     *
     * @return {@link List} 命中列表；每项含相对路径与「命中点所在方法体」源码
     * @throws IOException 源码目录缺失或不可读时抛出（空扫描面不得当作通过）
     */
    private static List<CallSite> scanDecryptCalls() throws IOException {
        Path sourceRoot = Path.of("src", "main", "java");
        assertThat(Files.isDirectory(sourceRoot))
                .as("源码目录必须存在，否则本判据变成空扫描（空扫描是 SKIP 不是 PASS）")
                .isTrue();

        List<CallSite> hits = new ArrayList<>();
        try (Stream<Path> files = Files.walk(sourceRoot)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                String content = Files.readString(file, StandardCharsets.UTF_8);
                String relative = sourceRoot.relativize(file).toString().replace('\\', '/');
                int fromIndex = 0;
                while ((fromIndex = content.indexOf(DECRYPT_CALL, fromIndex)) >= 0) {
                    hits.add(new CallSite(relative, enclosingMethod(content, fromIndex)));
                    fromIndex += DECRYPT_CALL.length();
                }
            }
        } catch (UncheckedIOException exception) {
            throw exception.getCause();
        }
        return hits;
    }

    /**
     * 判据纯函数：给定全部命中，返回 {@code null}（通过）或失败原因。
     *
     * @param hits 命中列表（文件相对路径 + 命中点所在方法体源码）
     * @return {@link String}；{@code null} 表示判据通过
     */
    static String judgeCallSites(List<CallSite> hits) {
        if (hits.isEmpty()) {
            return "全库未发现 .decrypt( 调用点——解密能力不应被摘除（扫描面异常或实现被删），须人工确认";
        }
        if (hits.size() != 1) {
            return "详设 §4.3：解密调用点只允许 1 处，实际 " + hits.size() + " 处："
                    + hits.stream().map(CallSite::file).toList();
        }
        CallSite hit = hits.get(0);
        if (!ONLY_ALLOWED_FILE.equals(hit.file())) {
            return "唯一解密调用点必须落在 " + ONLY_ALLOWED_FILE + "，实际 " + hit.file();
        }
        if (!hit.enclosingMethod().contains(AUDIT_WRITE)) {
            return "解密所在方法内必须同时写 audit_log（" + AUDIT_WRITE + "）——"
                    + "解密成功但留痕失败 = 一次无记录的个人信息访问（详设 §5.5.1 第 [7][8] 步同事务）";
        }
        return null;
    }

    /**
     * 取出「命中点所在方法」的方法体源码。
     *
     * <p>不做 Java 语法解析：以「4 空格缩进的访问修饰符 + 同一行含 (」识别方法声明行，
     * 取其后的首个 {@code {} 作块首，再按大括号配对取到块尾。取到的是<b>方法级</b>边界
     * （而非最内层块），故方法体内的 {@code if/try} 嵌套不影响判据。
     * 定位失败返回空串——由 {@link #judgeCallSites(List)} 判为失败（fail-closed），
     * 不静默通过。</p>
     *
     * @param source 源码全文
     * @param index  命中点（{@code .decrypt(} 的起始下标）
     * @return {@link String} 方法体源码（含花括号）；无法定位时为空串
     */
    static String enclosingMethod(String source, int index) {
        Matcher matcher = METHOD_DECL.matcher(source);
        int declarationStart = -1;
        while (matcher.find()) {
            if (matcher.start() > index) {
                break;
            }
            declarationStart = matcher.start();
        }
        if (declarationStart < 0) {
            return "";
        }
        int open = source.indexOf('{', declarationStart);
        if (open < 0) {
            return "";
        }
        int depth = 0;
        for (int i = open; i < source.length(); i++) {
            char c = source.charAt(i);
            if (c == '{') {
                depth++;
            } else if (c == '}') {
                depth--;
                if (depth == 0) {
                    return source.substring(open, i + 1);
                }
            }
        }
        return "";
    }

    /**
     * 统计子串出现次数（自检用）。
     *
     * @param text   被统计文本
     * @param needle 子串
     * @return int 出现次数
     */
    private static int countOf(String text, String needle) {
        int count = 0;
        int from = 0;
        while ((from = text.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }

    /**
     * 一处解密调用点及其所在方法体。
     *
     * @param file            命中文件（相对 {@code src/main/java}，正斜杠分隔）
     * @param enclosingMethod 命中点所在方法体源码；定位失败为空串
     */
    record CallSite(String file, String enclosingMethod) {
    }
}
