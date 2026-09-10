package com.s2s.server.common.error;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;

/**
 * {@link ErrorCode} 枚举守门测试。
 *
 * <p>职责：用会失败的自动化守住 PRD §12.5 唯一口径源——总数、无重复、码对齐 HTTP、
 * Retry-After 码集合逐一点名。本测试是防止历史编号冲突复现的唯一自动化手段
 * （详设 §2.3 单元测试要求；编码规范 §7.2 必测断言清单 ①）。
 *
 * <p>proof-first：本测试先于生产代码编写（U-3），首轮运行应编译失败。
 */
class ErrorCodeTest {

    /**
     * 断言枚举总数恰为 25（24 业务码 + {@code OK(0)}，编码规范 §0.2「不新增错误码」）。
     *
     * @param 无入参
     * @return void；断言失败即枚举被增删，违反「唯一口径源 PRD §12.5」纪律
     */
    @Test
    void totalCountIsExactly25() {
        assertThat(ErrorCode.values()).hasSize(25);
    }

    /**
     * 断言全部 {@code code} 无重复（详设 §2.3：新增前必须确认 code 未被占用）。
     *
     * @param 无入参
     * @return void；断言失败即出现重复 code 占号
     */
    @Test
    void codesAreUnique() {
        Set<Integer> distinctCodes = Arrays.stream(ErrorCode.values())
                .map(ErrorCode::getCode)
                .collect(Collectors.toSet());
        assertThat(distinctCodes).hasSize(ErrorCode.values().length);
    }

    /**
     * 断言 {@code code / 100 == httpStatus}（PRD §12.5 分段规则：前 3 位对齐 HTTP 状态码语义）；
     * {@code OK(0, 200)} 为规则豁免项（R-4 明列）。
     *
     * @param 无入参
     * @return void；断言失败即某枚举的 code 段与 httpStatus 失配
     */
    @Test
    void codeDividedBy100EqualsHttpStatusExceptOk() {
        for (ErrorCode errorCode : ErrorCode.values()) {
            if (errorCode == ErrorCode.OK) {
                continue;
            }
            assertThat(errorCode.getCode() / 100)
                    .as("ErrorCode.%s(code=%d) 的 code/100 须等于 httpStatus=%d（PRD §12.5 分段规则）",
                            errorCode.name(), errorCode.getCode(), errorCode.getHttpStatus())
                    .isEqualTo(errorCode.getHttpStatus());
        }
    }

    /**
     * 断言 {@code needRetryAfter=true} 恰好 8 个且逐一点名为
     * {@code 40105, 42901, 42902, 42903, 42904, 42905, 42906, 42907}
     * （编码规范 §3.2；PRD §12.5「Retry-After 响应头」补充条款）。
     *
     * @param 无入参
     * @return void；断言失败即 Retry-After 码集合漂移（抛此类异常必须带剩余秒数，缺即实现缺陷）
     */
    @Test
    void needRetryAfterCodesAreExactlyThe8Named() {
        Set<Integer> retryAfterCodes = Arrays.stream(ErrorCode.values())
                .filter(ErrorCode::isNeedRetryAfter)
                .map(ErrorCode::getCode)
                .collect(Collectors.toSet());
        assertThat(retryAfterCodes).containsExactlyInAnyOrder(
                40105, 42901, 42902, 42903, 42904, 42905, 42906, 42907);
    }
}
