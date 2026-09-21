package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.dto.MyProfile;
import com.s2s.server.auth.dto.UpdateProfileRequest;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.moderation.MediaAuditChecker;
import com.s2s.server.common.moderation.SensitiveWordChecker;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link UserService} 本人资料测试（[123] U8；详设 §5.1；plan U8 验收三条）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>查本人资料 → 返回 MyProfile 白名单（敏感列 real_name_enc/id_card_hash 不投影）；</li>
 *   <li>改昵称命中敏感词 → 40901；</li>
 *   <li>改头像 media_id 未过审 → 40902；</li>
 *   <li>改昵称成功 → updateById 落库并返回更新后 MyProfile。</li>
 * </ol>
 *
 * <p>测试策略：UserMapper/敏感词检测/媒体审核全部 mock，聚焦 {@code UserService}
 * 编排——白名单投影（{@code MyProfile.from}）、校验顺序（敏感词→媒体审核）、局部更新。</p>
 */
class UserServiceTest {

    /** mock 的用户 Mapper。 */
    private UserMapper userMapper;

    /** mock 的敏感词检测。 */
    private SensitiveWordChecker sensitiveWordChecker;

    /** mock 的媒体审核。 */
    private MediaAuditChecker mediaAuditChecker;

    /** 被测用户资料服务。 */
    private UserService userService;

    /**
     * 每测前置：构造 mock 依赖并装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        userMapper = mock(UserMapper.class);
        sensitiveWordChecker = mock(SensitiveWordChecker.class);
        mediaAuditChecker = mock(MediaAuditChecker.class);
        userService = new UserService(userMapper, sensitiveWordChecker, mediaAuditChecker);
    }

    /**
     * 场景一：查本人资料 → 返回白名单 MyProfile，敏感列不投影。
     *
     * @return void
     */
    @Test
    void getMyProfileReturnsWhitelistedProfile() {
        UserEntity user = existingUserWithSensitiveColumns();
        when(userMapper.selectById(1L)).thenReturn(user);

        MyProfile profile = userService.getMyProfile(1L);

        assertThat(profile.id()).isEqualTo(1L);
        assertThat(profile.nickname()).isEqualTo("昵称");
        assertThat(profile.phoneMask()).isEqualTo("138****8000");
        assertThat(profile.defaultRadius()).isEqualTo("3");
        // MyProfile 类型无 realNameEnc / idCardHash 字段，白名单投影由类型保证
    }

    /**
     * 场景二：改昵称命中敏感词 → 40901，且不落库。
     *
     * @return void
     */
    @Test
    void updateNicknameRejectsSensitiveWord() {
        when(userMapper.selectById(1L)).thenReturn(existingUser());
        doThrow(BizException.of(ErrorCode.SENSITIVE_WORD))
                .when(sensitiveWordChecker).check("违禁词");

        assertThatThrownBy(() -> userService.updateMyProfile(1L,
                new UpdateProfileRequest("违禁词", null, null)))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.SENSITIVE_WORD));
        verify(userMapper, org.mockito.Mockito.never()).updateById(any(UserEntity.class));
    }

    /**
     * 场景三：改头像 media_id 未过审 → 40902，且不落库。
     *
     * @return void
     */
    @Test
    void updateAvatarRejectsUnapprovedMedia() {
        when(userMapper.selectById(1L)).thenReturn(existingUser());
        doThrow(BizException.of(ErrorCode.IMAGE_REJECTED))
                .when(mediaAuditChecker).checkApproved("media-1");

        assertThatThrownBy(() -> userService.updateMyProfile(1L,
                new UpdateProfileRequest(null, "media-1", null)))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.IMAGE_REJECTED));
        verify(userMapper, org.mockito.Mockito.never()).updateById(any(UserEntity.class));
    }

    /**
     * 场景四：改昵称成功 → 落库并返回更新后 MyProfile。
     *
     * @return void
     */
    @Test
    void updateNicknameSucceeds() {
        when(userMapper.selectById(1L)).thenReturn(existingUser());

        MyProfile profile = userService.updateMyProfile(1L,
                new UpdateProfileRequest("新昵称", null, null));

        assertThat(profile.nickname()).isEqualTo("新昵称");
        verify(userMapper).updateById(any(UserEntity.class));
    }

    /**
     * 构造一个老用户实体（含脱敏手机号 + 默认档）。
     *
     * @return {@link UserEntity} 用户实体
     */
    private UserEntity existingUser() {
        UserEntity user = new UserEntity();
        user.setId(1L);
        user.setPhoneMask("138****8000");
        user.setNickname("昵称");
        user.setRealnameStatus("none");
        user.setDefaultRadius("3");
        return user;
    }

    /**
     * 构造带敏感列的用户实体（验证白名单投影不泄漏 real_name_enc/id_card_hash）。
     *
     * @return {@link UserEntity} 含敏感列的用户实体
     */
    private UserEntity existingUserWithSensitiveColumns() {
        UserEntity user = existingUser();
        user.setRealNameEnc(new byte[] {1, 2, 3});
        user.setIdCardHash(new byte[] {4, 5, 6});
        return user;
    }
}
