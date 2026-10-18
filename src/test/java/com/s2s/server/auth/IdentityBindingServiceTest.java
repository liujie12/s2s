package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.mapper.UserIdentityMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link IdentityBindingService} 门禁测试（B2-6a，2026-10-18 裁定）。
 *
 * <p>覆盖：已绑定手机号放行、未绑定抛 40302（扩展语义）、身份类型查询分流。</p>
 */
class IdentityBindingServiceTest {

    /** mock 的身份 Mapper。 */
    private UserIdentityMapper userIdentityMapper;

    /** 被测服务。 */
    private IdentityBindingService service;

    /**
     * 每测前置：装配 mock Mapper 与被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        userIdentityMapper = mock(UserIdentityMapper.class);
        service = new IdentityBindingService(userIdentityMapper);
    }

    /**
     * 已绑定手机号：查询计数 > 0 时放行。
     *
     * @return void
     */
    @Test
    void requirePhoneBoundPassesWhenBound() {
        when(userIdentityMapper.selectCount(any())).thenReturn(1L);

        assertThat(service.isPhoneBound(1L)).isTrue();
        service.requirePhoneBound(1L);
    }

    /**
     * 未绑定手机号：拒绝并回 40302（需完成必要认证/绑定）。
     *
     * @return void
     */
    @Test
    void requirePhoneBoundRejectsWhenUnbound() {
        when(userIdentityMapper.selectCount(any())).thenReturn(0L);

        assertThat(service.isPhoneBound(1L)).isFalse();
        assertThatThrownBy(() -> service.requirePhoneBound(1L))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.QUALIFICATION_NEEDED));
    }

    /**
     * 身份类型分流：微信身份查询命中不影响手机号判断（各自独立计数）。
     *
     * @return void
     */
    @Test
    void wechatBoundIsQueriedIndependently() {
        when(userIdentityMapper.selectCount(any())).thenReturn(1L, 0L);

        assertThat(service.isWechatBound(1L)).isTrue();
        assertThat(service.isPhoneBound(1L)).isFalse();
    }
}
