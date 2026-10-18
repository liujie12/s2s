package com.s2s.server.auth;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.auth.entity.UserIdentityEntity;
import com.s2s.server.auth.mapper.UserIdentityMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.springframework.stereotype.Component;

/**
 * 登录身份绑定状态查询与门禁（B2-6a，2026-10-18 裁定）。
 *
 * <p>职责：
 * <ul>
 *   <li>查询当前账号是否已绑定手机号 / 微信（供 {@code MyProfile} 投影与设置页展示）；</li>
 *   <li>发布（{@code POST /posts}）与联系（{@code GET /posts/{id}/contact}）的
 *       「必须已绑定手机号」门禁（架构 §5.1.1 门禁②）。</li>
 * </ul></p>
 *
 * <p>拒绝码：复用 {@link ErrorCode#QUALIFICATION_NEEDED}（40302）。该码于
 * 2026-10-18 由「高敏类目未认证」扩展为「需完成必要认证/绑定」类门禁，
 * 客户端按调用场景显示「请先绑定手机号」或跳认证页。</p>
 */
@Component
public class IdentityBindingService {

    /** 身份归一化 Mapper。 */
    private final UserIdentityMapper userIdentityMapper;

    /**
     * 构造身份绑定服务。
     *
     * @param userIdentityMapper 身份归一化 Mapper
     */
    public IdentityBindingService(UserIdentityMapper userIdentityMapper) {
        this.userIdentityMapper = userIdentityMapper;
    }

    /**
     * 判断某账号是否已绑定指定类型的身份。
     *
     * @param userId       用户 ID（调用方保证非空）
     * @param identityType 身份类型（{@link UserIdentityTypes} 常量）
     * @return boolean true 表示已绑定
     */
    public boolean hasIdentity(Long userId, String identityType) {
        Long count = userIdentityMapper.selectCount(
                new QueryWrapper<UserIdentityEntity>()
                        .eq("user_id", userId)
                        .eq("identity_type", identityType));
        return count != null && count > 0;
    }

    /**
     * 判断某账号是否已绑定手机号。
     *
     * @param userId 用户 ID
     * @return boolean true 表示已绑定手机号
     */
    public boolean isPhoneBound(Long userId) {
        return hasIdentity(userId, UserIdentityTypes.PHONE);
    }

    /**
     * 判断某账号是否已绑定微信。
     *
     * @param userId 用户 ID
     * @return boolean true 表示已绑定微信
     */
    public boolean isWechatBound(Long userId) {
        return hasIdentity(userId, UserIdentityTypes.WECHAT);
    }

    /**
     * 发布/联系门禁：未绑定手机号即拒绝。
     *
     * @param userId 当前登录用户 ID
     * @return void；已绑定手机号时正常返回
     * @throws BizException 未绑定手机号 → 40302（需完成必要认证/绑定）
     */
    public void requirePhoneBound(Long userId) {
        if (!isPhoneBound(userId)) {
            throw BizException.of(ErrorCode.QUALIFICATION_NEEDED);
        }
    }
}
