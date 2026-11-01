package com.s2s.server.common.moderation;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import jakarta.annotation.PostConstruct;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * 基于前缀树的敏感词检测（替换 Batch1 的恒放行桩）。
 *
 * <p><b>为什么用本地前缀树而不是接第三方内容安全 API</b>：消息发送是同步链路，
 * 外呼会把 P99 直接推到网络超时量级；且第三方服务需要额外凭据与计费。
 * 词库随包发布、万级词条下匹配是微秒级，足够覆盖「辱骂 + 违法推广」两类高频场景。
 * 后续需要图片/变体识别时，再在调用点前置一层异步审核，不改变本接口。</p>
 *
 * <p><b>归一化</b>：匹配前去掉空白与常见分隔符（`*`、`-`、`_`、`.`、全角标点等）
 * 并转小写，抵住「傻 逼」「傻*逼」「CNM」这类最朴素的绕过方式。</p>
 *
 * <p><b>命中即抛</b>：{@link ErrorCode#SENSITIVE_WORD}（40901），文案由全局异常处理
 * 统一回显，<b>不回显命中词</b>，避免帮用户试探词库边界。</p>
 */
@Component
public class TrieSensitiveWordChecker implements SensitiveWordChecker {

    /** 日志：只记词库规模，不记命中内容（内容本身可能违规，不入日志）。 */
    private static final Logger log = LoggerFactory.getLogger(TrieSensitiveWordChecker.class);

    /** 内置词库路径（classpath）。 */
    private static final String WORD_RESOURCE = "/moderation/sensitive-words.txt";

    /** 前缀树根节点。 */
    private final Node root = new Node();

    /** 已加载词条数（观测用）。 */
    private int wordCount;

    /**
     * 启动时加载内置词库并构建前缀树。
     *
     * @throws IllegalStateException 词库缺失或为空——敏感词是安全闸门，
     *         不允许「静默退化为全放行」后才发现
     */
    @PostConstruct
    void load() {
        try (InputStream input = TrieSensitiveWordChecker.class.getResourceAsStream(WORD_RESOURCE)) {
            if (input == null) {
                throw new IllegalStateException("敏感词库缺失：" + WORD_RESOURCE);
            }
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(input, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    String word = line.trim();
                    if (word.isEmpty() || word.startsWith("#")) {
                        continue;
                    }
                    insert(normalize(word));
                }
            }
        } catch (IOException e) {
            throw new IllegalStateException("敏感词库读取失败：" + WORD_RESOURCE, e);
        }
        if (wordCount == 0) {
            throw new IllegalStateException("敏感词库为空：" + WORD_RESOURCE);
        }
        log.info("敏感词库加载完成，共 {} 个词条", wordCount);
    }

    /**
     * 检测文本是否命中敏感词。
     *
     * @param text 待检测文本
     * @throws BizException 命中时抛 {@link ErrorCode#SENSITIVE_WORD}
     */
    @Override
    public void check(String text) {
        if (text == null || text.isBlank()) {
            return;
        }
        if (contains(normalize(text))) {
            throw BizException.of(ErrorCode.SENSITIVE_WORD);
        }
    }

    /**
     * 把词条插入前缀树。
     *
     * @param word 已归一化的词条
     */
    private void insert(String word) {
        Node node = root;
        for (int index = 0; index < word.length(); index++) {
            node = node.children.computeIfAbsent(word.charAt(index), key -> new Node());
        }
        if (!node.terminal) {
            node.terminal = true;
            wordCount++;
        }
    }

    /**
     * 在前缀树上扫描文本，任一位置命中完整词条即返回 true。
     *
     * @param text 已归一化文本
     * @return boolean 是否命中
     */
    private boolean contains(String text) {
        for (int start = 0; start < text.length(); start++) {
            Node node = root;
            for (int index = start; index < text.length(); index++) {
                node = node.children.get(text.charAt(index));
                if (node == null) {
                    break;
                }
                if (node.terminal) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * 归一化：小写化，并去掉空白与常见分隔符，抵住最朴素的绕过写法。
     *
     * @param text 原始文本
     * @return {@link String} 归一化结果
     */
    private String normalize(String text) {
        StringBuilder builder = new StringBuilder(text.length());
        for (int index = 0; index < text.length(); index++) {
            char value = Character.toLowerCase(text.charAt(index));
            if (Character.isWhitespace(value) || isSeparator(value)) {
                continue;
            }
            builder.append(value);
        }
        return builder.toString();
    }

    /**
     * 判断字符是否为可忽略的分隔符（用户插入用来打断词条的字面量）。
     *
     * @param value 字符
     * @return boolean 是否忽略
     */
    private boolean isSeparator(char value) {
        return switch (value) {
            case '*', '-', '_', '.', '~', '·', ',', '，', '。', '、', '!', '！', '?', '？' -> true;
            default -> false;
        };
    }

    /**
     * 前缀树节点。
     */
    private static final class Node {

        /** 子节点表。 */
        private final Map<Character, Node> children = new HashMap<>();

        /** 是否有词条在此结束。 */
        private boolean terminal;
    }
}
