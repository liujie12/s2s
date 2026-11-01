package com.s2s.server.common.moderation;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.s2s.server.common.error.BizException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 敏感词检测测试：命中、变体绕过、正常文本放行。
 *
 * <p>核心断言是「用户实际输入的那几类写法必须被拦住」——词库里有词但匹配不到，
 * 等于没接；反之正常聊天被误拦，用户会直接放弃使用。</p>
 */
class TrieSensitiveWordCheckerTest {

    /** 被测对象（真实词库）。 */
    private final TrieSensitiveWordChecker checker = new TrieSensitiveWordChecker();

    /**
     * 每个用例前加载内置词库。
     */
    @BeforeEach
    void setUp() {
        checker.load();
    }

    /**
     * 含内置辱骂词的句子必须被拒（40901）。
     *
     * @return void；断言失败即敏感词库没生效
     */
    @Test
    void blocksConfiguredWord() {
        assertThatThrownBy(() -> checker.check("你就是个傻逼"))
                .isInstanceOf(BizException.class);
    }

    /**
     * 插入空格/符号的变体必须同样命中。
     *
     * @return void；断言失败即最朴素的绕过方式都拦不住
     */
    @Test
    void blocksSeparatedVariant() {
        assertThatThrownBy(() -> checker.check("傻 逼"))
                .isInstanceOf(BizException.class);
        assertThatThrownBy(() -> checker.check("傻*逼"))
                .isInstanceOf(BizException.class);
    }

    /**
     * 正常聊天内容不得误伤。
     *
     * @return void；断言失败即词库过宽，会拦掉正常消息
     */
    @Test
    void allowsNormalText() {
        assertThatCode(() -> checker.check("你好，我想问下合租还有空房吗"))
                .doesNotThrowAnyException();
        assertThatCode(() -> checker.check("这个宝贝还在吗"))
                .doesNotThrowAnyException();
    }

    /**
     * 空值与空白文本直接放行（消息正文由参数校验负责，不在这里重复报错）。
     *
     * @return void
     */
    @Test
    void allowsBlankText() {
        assertThatCode(() -> checker.check(null)).doesNotThrowAnyException();
        assertThatCode(() -> checker.check("   ")).doesNotThrowAnyException();
    }
}
