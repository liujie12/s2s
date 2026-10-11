package com.s2s.server.auth;

import com.s2s.server.auth.dto.MyProfile;
import com.s2s.server.auth.dto.UpdateProfileRequest;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.moderation.MediaAuditChecker;
import com.s2s.server.common.moderation.SensitiveWordChecker;
import org.springframework.stereotype.Service;

/**
 * 用户资料服务（[123] U3 骨架 → U8 实现 {@code getMyProfile}/{@code updateMyProfile}）。
 *
 * <p>职责：获取/更新本人资料（{@code GET/PATCH /users/me}），出参严格走对外视图
 * 白名单（{@link MyProfile#from(UserEntity)} 唯一投影），UserEntity 不得直接返回。</p>
 *
 * <p>关键实现（详设 §5.1）：
 * <ul>
 *   <li>昵称过敏感词 → {@code 40901}（{@link SensitiveWordChecker}，Batch1 桩）；</li>
 *   <li>头像 media_id 须 audit_status=pass 否则 {@code 40902}
 *       （{@link MediaAuditChecker}，Batch1 桩）；</li>
 *   <li>局部更新，仅提交变更字段（契约 {@code minProperties: 1}）。</li>
 * </ul>
 *
 * <p>头像 URL 转换：Batch1 media 服务未落地，avatar_media_id 校验通过后先存原值
 * （TODO：post 域 MediaService 落地后转 OSS 临时访问地址）。</p>
 *
 * <p>出处：详设 §5.1（auth 域）、plan R5/R6、KTD4（白名单投影）。</p>
 */
@Service
public class UserService {

    /** 用户 Mapper。 */
    private final UserMapper userMapper;

    /** 敏感词检测（昵称，Batch1 桩）。 */
    private final SensitiveWordChecker sensitiveWordChecker;

    /** 媒体审核（头像，Batch1 桩）。 */
    private final MediaAuditChecker mediaAuditChecker;

    /**
     * 构造用户资料服务，注入持久层、敏感词检测与媒体审核。
     *
     * @param userMapper          用户 Mapper
     * @param sensitiveWordChecker 敏感词检测（昵称）
     * @param mediaAuditChecker    媒体审核（头像）
     */
    public UserService(UserMapper userMapper, SensitiveWordChecker sensitiveWordChecker,
            MediaAuditChecker mediaAuditChecker) {
        this.userMapper = userMapper;
        this.sensitiveWordChecker = sensitiveWordChecker;
        this.mediaAuditChecker = mediaAuditChecker;
    }

    /**
     * 获取本人资料：查 user 投影为 MyProfile（白名单）。
     *
     * @param userId 登录用户 ID（由 AuthContext 提供）
     * @return {@link MyProfile} 本人资料
     * @throws BizException 用户不存在（已注销/删除）→ 40101
     */
    public MyProfile getMyProfile(Long userId) {
        UserEntity user = userMapper.selectById(userId);
        if (user == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return MyProfile.from(user);
    }

    /**
     * 更新本人资料：局部更新昵称/头像/默认半径，返回更新后的 MyProfile。
     *
     * <p>执行顺序：查 user（不存在 40101）→ 昵称敏感词检测（40901）→ 头像媒体审核
     * （40902）→ 更新提交字段 → 返回投影。校验全过后才写库，避免「改了昵称、头像被拒」
     * 的局部提交。</p>
     *
     * @param userId  登录用户 ID
     * @param request 更新请求（nickname/avatar_media_id/default_radius，至少一项）
     * @return {@link MyProfile} 更新后的本人资料
     * @throws BizException 昵称敏感词 → 40901；头像未过审 → 40902；用户不存在 → 40101
     */
    public MyProfile updateMyProfile(Long userId, UpdateProfileRequest request) {
        if (request.nickname() == null && request.avatarMediaId() == null
                && request.defaultRadius() == null) {
            // 契约 minProperties: 1 —— 空请求体按参数非法处理
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        UserEntity user = userMapper.selectById(userId);
        if (user == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }

        if (request.nickname() != null) {
            sensitiveWordChecker.check(request.nickname());
            user.setNickname(request.nickname());
        }
        if (request.avatarMediaId() != null) {
            mediaAuditChecker.checkApproved(request.avatarMediaId());
            // TODO(post 域落地后)：media_id 转 OSS 临时访问地址再落 avatar_url
            user.setAvatarUrl(request.avatarMediaId());
        }
        if (request.defaultRadius() != null) {
            user.setDefaultRadius(request.defaultRadius());
        }

        userMapper.updateById(user);
        return MyProfile.from(user);
    }

    /**
     * 读用户实名状态（供 cert 域查询；详设 §4.2 域间只调 service，cert 禁跨域 user mapper）。
     *
     * <p>{@code user.realname_status} 的读入口收口于本方法——cert 域要判断「是否已实名」
     * 不得自行注入 {@link UserMapper}（跨域 mapper 红线）。</p>
     *
     * @param userId 用户 ID
     * @return {@link String} 实名状态（{@code none/pending/passed/rejected}）；
     *         用户不存在返回 {@code null}（由调用方决定兜底口径）
     */
    public String realnameStatusOf(Long userId) {
        UserEntity user = userMapper.selectById(userId);
        return user == null ? null : user.getRealnameStatus();
    }

    /**
     * 写回实名认证通过结果（供 cert 域调用；详设 §4.2 域间只调 service）。
     *
     * <p>姓名/身份证的加密与盲索引在 cert 域完成（{@code CryptoFacade} 与 {@code BlindIndex}），
     * 本方法只负责把已算好的值 update 进 {@code user} 表——职责边界：核验流程归 cert 域、
     * user 表持久化归 auth 域，避免 cert 域直接写 user 表（跨域 mapper 红线）。
     * 实名状态值由 cert 域传入（{@code CertService.REALNAME_STATUS_PASSED}），本类不复制
     * 该字面量（编码规范红线「不复制字面量」）。</p>
     *
     * @param userId      用户 ID
     * @param realnameStatus 实名状态（由 cert 域传入，如 {@code passed}）
     * @param realNameEnc 姓名 AEAD 密文（AAD 绑定 user_id，cert 域已加密）
     * @param idCardHash  身份证 HMAC 盲索引（cert 域已算）
     * @param idCardLast4 身份证后 4 位明文
     * @param keyVersion  密钥版本号（cert 域加密时取）
     * @throws BizException 用户不存在（已注销/删除）→ 40101
     */
    public void applyRealnameResult(Long userId, String realnameStatus, byte[] realNameEnc,
            byte[] idCardHash, String idCardLast4, int keyVersion) {
        UserEntity user = userMapper.selectById(userId);
        if (user == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        user.setRealnameStatus(realnameStatus);
        user.setRealNameEnc(realNameEnc);
        user.setIdCardHash(idCardHash);
        user.setIdCardLast4(idCardLast4);
        user.setKeyVersion(keyVersion);
        userMapper.updateById(user);
    }
}
