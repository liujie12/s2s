package com.s2s.server.auth;

import com.s2s.server.auth.dto.SettingsResponse;
import com.s2s.server.auth.dto.SettingsUpdateRequest;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.auth.mapper.UserSettingMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.Map;
import java.util.Set;
import org.springframework.stereotype.Service;

/**
 * 设置域服务（[B2-11]；openapi {@code GET/PATCH /settings}；PRD §13/§9.3）。
 *
 * <p>归 auth 域：设置是「登录用户偏好」，与 {@code /users/me} 同源（{@code default_radius} 同列、
 * 同域 {@link UserMapper}）。通知开关落 {@code user_setting} 表（V6 迁移，2026-10-11 DEC-33），
 * 缺行即全默认（四项全开）。</p>
 *
 * <p><b>口径</b>：{@code PATCH} 为局部更新，仅提交字段生效；隐私项只读、提交即忽略；
 * {@code default_radius} 必须落在 {@code RadiusEnum} 内，否则 {@code 40001}。写动作只在确有变更时发生
 * （仅改 {@code default_radius} 时不会凭空创建 {@code user_setting} 行）。</p>
 */
@Service
public class SettingService {

    /** 联系方式展示策略：仅联系中转时展示（openapi {@code SettingsResponse.privacy.contact_display} 唯一值）。 */
    private static final String CONTACT_DISPLAY_TRANSIT_ONLY = "transit_only";

    /** 默认检索半径合法档位（openapi {@code RadiusEnum}：1/3/5/10 km、city 全城）。 */
    private static final Set<String> RADIUS_VALUES = Set.of("1", "3", "5", "10", "city");

    private final UserSettingMapper userSettingMapper;
    private final UserMapper userMapper;

    /**
     * 构建设置域服务。
     *
     * @param userSettingMapper 通知开关 Mapper（本域）
     * @param userMapper        用户 Mapper（本域，读/写 {@code default_radius}）
     */
    public SettingService(UserSettingMapper userSettingMapper, UserMapper userMapper) {
        this.userSettingMapper = userSettingMapper;
        this.userMapper = userMapper;
    }

    /**
     * 读取本人设置。
     *
     * @param userId 登录用户 ID（调用方保证非 null）
     * @return {@link SettingsResponse}
     * @throws BizException {@code 40101} 用户不存在（已注销/删除）
     */
    public SettingsResponse get(Long userId) {
        UserEntity user = requireUser(userId);
        Map<String, Object> row = userSettingMapper.selectByUserId(userId);
        return build(user.getDefaultRadius(),
                row == null || row.get("notify_enabled") == null
                        ? true : isTrue(row.get("notify_enabled")),
                row == null || row.get("notify_system") == null
                        ? true : isTrue(row.get("notify_system")),
                row == null || row.get("notify_interaction") == null
                        ? true : isTrue(row.get("notify_interaction")),
                row == null || row.get("notify_cert") == null
                        ? true : isTrue(row.get("notify_cert")),
                personalizedOf(row),
                aiImproveOf(row));
    }

    /**
     * 修改本人设置（局部更新）。
     *
     * @param userId  登录用户 ID（调用方保证非 null）
     * @param request 更新请求；{@code null} 视为空补丁（不写任何字段）
     * @return {@link SettingsResponse} 更新后的完整设置
     * @throws BizException {@code 40101} 用户不存在；{@code 40001} {@code default_radius} 不在 {@code RadiusEnum} 内
     */
    public SettingsResponse update(Long userId, SettingsUpdateRequest request) {
        UserEntity user = requireUser(userId);
        Map<String, Object> row = userSettingMapper.selectByUserId(userId);

        boolean enabled = row == null || row.get("notify_enabled") == null ? true : isTrue(row.get("notify_enabled"));
        boolean system = row == null || row.get("notify_system") == null ? true : isTrue(row.get("notify_system"));
        boolean interaction = row == null || row.get("notify_interaction") == null
                ? true : isTrue(row.get("notify_interaction"));
        boolean cert = row == null || row.get("notify_cert") == null ? true : isTrue(row.get("notify_cert"));
        boolean personalized = personalizedOf(row);
        boolean aiImprove = aiImproveOf(row);
        String radius = user.getDefaultRadius();
        boolean touched = false;

        if (request != null) {
            if (request.defaultRadius() != null) {
                if (!RADIUS_VALUES.contains(request.defaultRadius())) {
                    throw BizException.of(ErrorCode.PARAM_INVALID);
                }
                radius = request.defaultRadius();
                user.setDefaultRadius(radius);
                userMapper.updateById(user);
            }
            SettingsUpdateRequest.NotifyPatch patch = request.notifyPatch();
            if (patch != null) {
                if (patch.enabled() != null) {
                    enabled = patch.enabled();
                    touched = true;
                }
                if (patch.system() != null) {
                    system = patch.system();
                    touched = true;
                }
                if (patch.interaction() != null) {
                    interaction = patch.interaction();
                    touched = true;
                }
                if (patch.cert() != null) {
                    cert = patch.cert();
                    touched = true;
                }
            }
            SettingsUpdateRequest.PrivacyPatch privacyPatch = request.privacyPatch();
            if (privacyPatch != null) {
                if (privacyPatch.personalizedRecommend() != null) {
                    personalized = privacyPatch.personalizedRecommend();
                    touched = true;
                }
                if (privacyPatch.aiImprove() != null) {
                    aiImprove = privacyPatch.aiImprove();
                    touched = true;
                }
            }
        }

        if (touched) {
            userSettingMapper.upsert(userId, enabled, system, interaction, cert, personalized,
                    aiImprove);
        }
        return build(radius, enabled, system, interaction, cert, personalized, aiImprove);
    }

    /**
     * 判断某用户的个性化排序是否开启（供排序链路判定，不抛业务异常）。
     *
     * <p>刻意<b>不</b>调 {@link #get(Long)}：排序是高频读路径，且游客/无设置行都应按默认
     * （开启）处理，不该因用户行缺失而影响检索。</p>
     *
     * @param userId 用户 ID（游客传 {@code null}）
     * @return boolean {@code false} 表示用户已关闭个性化排序（列表应回落为仅按距离排序）；
     *         无设置行或 {userId} 为 {@code null} 时返回 {@code true}
     */
    public boolean isPersonalizedRecommendEnabled(Long userId) {
        if (userId == null) {
            return true;
        }
        return personalizedOf(userSettingMapper.selectByUserId(userId));
    }

    /**
     * 组装设置响应（{@code contactDisplay} 为固定只读值）。
     *
     * @param radius       默认检索半径档位
     * @param enabled      通知总开关
     * @param system       系统通知分通道
     * @param interaction  互动通知分通道
     * @param cert         认证通知分通道
     * @param personalized 个性化排序开关
     * @param aiImprove    AI 数据用于改进解析开关
     * @return {@link SettingsResponse}
     */
    private SettingsResponse build(String radius, boolean enabled, boolean system, boolean interaction,
            boolean cert, boolean personalized, boolean aiImprove) {
        return new SettingsResponse(
                new SettingsResponse.NotifySettings(enabled, system, interaction, cert),
                radius,
                new SettingsResponse.PrivacySettings(CONTACT_DISPLAY_TRANSIT_ONLY, personalized,
                        aiImprove));
    }

    /**
     * 从设置行读个性化排序开关（缺行/缺列一律默认开启）。
     *
     * @param row {@code user_setting} 行（可空）
     * @return boolean true＝开启
     */
    private static boolean personalizedOf(Map<String, Object> row) {
        if (row == null || row.get("personalized_recommend") == null) {
            return true;
        }
        return isTrue(row.get("personalized_recommend"));
    }

    /**
     * 从设置行读「AI 数据用于改进解析」开关（缺行/缺列一律默认开启）。
     *
     * @param row {@code user_setting} 行（可空）
     * @return boolean true＝允许用于改进解析
     */
    private static boolean aiImproveOf(Map<String, Object> row) {
        if (row == null || row.get("ai_improve_enabled") == null) {
            return true;
        }
        return isTrue(row.get("ai_improve_enabled"));
    }

    /**
     * 取用户行，不存在抛 {@code 40101}。
     *
     * @param userId 用户 ID
     * @return {@link UserEntity}
     * @throws BizException {@code 40101}
     */
    private UserEntity requireUser(Long userId) {
        UserEntity user = userMapper.selectById(userId);
        if (user == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return user;
    }

    /**
     * 把 JDBC 取回的开关列判为布尔（{@code TINYINT} 经驱动可能是 {@link Number} 或 {@link Boolean}）。
     *
     * @param value 列值
     * @return boolean true＝开
     */
    private static boolean isTrue(Object value) {
        if (value instanceof Boolean bool) {
            return bool;
        }
        return value instanceof Number number && number.intValue() != 0;
    }
}
