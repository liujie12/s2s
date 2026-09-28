package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
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
 */
class CryptoFacadeCallSiteTest {

    /** 被守门的调用形态。 */
    private static final String DECRYPT_CALL = ".decrypt(";

    /** 唯一允许的调用点所在文件（相对仓库根）。 */
    private static final String ONLY_ALLOWED_FILE =
            "ContactService.java";

    /**
     * {@code .decrypt(} 全库出现次数必须恰为 1，且位于 contact 域的
     * {@code ContactService}（Batch1 唯一解密点）。
     *
     * @throws IOException 源码目录不可读时抛出（扫描面缺失属测试环境缺陷，
     *         不能静默当成通过——「扫描面为空是 SKIP 不是 PASS」）
     */
    @Test
    void decryptCallSiteCountIsExactlyOne() throws IOException {
        Path sourceRoot = Path.of("src", "main", "java");
        assertThat(Files.isDirectory(sourceRoot))
                .as("源码目录必须存在，否则本判据变成空扫描（空扫描是 SKIP 不是 PASS）")
                .isTrue();

        List<String> hits = new ArrayList<>();
        try (Stream<Path> files = Files.walk(sourceRoot)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                String content = Files.readString(file, StandardCharsets.UTF_8);
                int fromIndex = 0;
                while ((fromIndex = content.indexOf(DECRYPT_CALL, fromIndex)) >= 0) {
                    hits.add(sourceRoot.relativize(file).toString());
                    fromIndex += DECRYPT_CALL.length();
                }
            }
        } catch (UncheckedIOException exception) {
            throw exception.getCause();
        }

        assertThat(hits)
                .as("详设 §4.3：全系统解密调用点只允许 1 处（新增即架构变更须评审）")
                .hasSize(1);
        assertThat(hits.get(0))
                .as("唯一解密调用点必须落在 contact 域的 ContactService（详设 §4.3 指定）")
                .endsWith(ONLY_ALLOWED_FILE);
    }
}
