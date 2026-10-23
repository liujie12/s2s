package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.dto.SettingsResponse;
import com.s2s.server.auth.dto.SettingsUpdateRequest;
import com.s2s.server.auth.entity.UserEntity;
import com.s2s.server.auth.mapper.UserMapper;
import com.s2s.server.auth.mapper.UserSettingMapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link SettingService} 与契约映射测试（[B2-11]；openapi {@code GET/PATCH /settings}）。
 *
 * <p>覆盖四类易错口径：① 未登录/用户不存在 → {@code 40101}；② 通知开关缺行兜底为全默认（全开）；
 * ③ 局部更新语义（只改半径不建 {@code user_setting} 行、只改通知不动 {@code user}）；
 * ④ {@code default_radius} 白名单（{@code RadiusEnum}）与响应 JSON 键名契约。</p>
 *
 * <p>纯单元测试：两个 Mapper 以 Mockito 替身注入，不连库。</p>
 */
class SettingServiceTest {

    /** 用户 ID 夹具。 */
    private static final Long USER_ID = 4004L;

    private UserSettingMapper userSettingMapper;
    private UserMapper userMapper;
    private SettingService service;

    /**
     * 装配替身服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        userSettingMapper = mock(UserSettingMapper.class);
        userMapper = mock(UserMapper.class);
        service = new SettingService(userSettingMapper, userMapper);
    }

    /**
     * 用户不存在 → {@code 40101}，不触达设置表。
     *
     * @return void
     */
    @Test
    @DisplayName("读取：用户不存在 → 40101")
    void getUnknownUser() {
        when(userMapper.selectById(USER_ID)).thenReturn(null);

        assertThatThrownBy(() -> service.get(USER_ID))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isSameAs(ErrorCode.UNAUTHORIZED));
        verify(userSettingMapper, never()).selectByUserId(any());
    }

    /**
     * 缺行 → 通知开关四项全默认（全开），半径取 {@code user.default_radius}，隐私项固定。
     *
     * @return void；断言失败即缺行被误判为「全关」
     */
    @Test
    @DisplayName("读取：缺行 → 全开默认 + 半径来自 user + 隐私项固定")
    void getDefaultsWhenRowAbsent() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("3"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(null);

        SettingsResponse response = service.get(USER_ID);

        assertThat(response.notifySettings().enabled()).isTrue();
        assertThat(response.notifySettings().system()).isTrue();
        assertThat(response.notifySettings().interaction()).isTrue();
        assertThat(response.notifySettings().cert()).isTrue();
        assertThat(response.defaultRadius()).isEqualTo("3");
        assertThat(response.privacy().contactDisplay()).isEqualTo("transit_only");
        assertThat(response.privacy().personalizedRecommend()).isTrue();
    }

    /**
     * 已有行 → 按行值回读（0 视为关）。
     *
     * @return void
     */
    @Test
    @DisplayName("读取：已有行按值回读（TINYINT 0 → false）")
    void getReflectsExistingRow() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("5"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(settingRow(0, 1, 1, 0));

        SettingsResponse response = service.get(USER_ID);

        assertThat(response.notifySettings().enabled()).isFalse();
        assertThat(response.notifySettings().cert()).isFalse();
        assertThat(response.notifySettings().system()).isTrue();
    }

    /**
     * 只提交 {@code default_radius} → 写 {@code user}、不写设置表（不凭空建行）。
     *
     * @return void；断言失败即局部更新越界写无关表
     */
    @Test
    @DisplayName("更新：只改半径 → 写 user，不 upsert 设置表")
    void updateRadiusOnly() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("3"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(null);

        SettingsResponse response = service.update(USER_ID,
                new SettingsUpdateRequest(null, "10", null));

        assertThat(response.defaultRadius()).isEqualTo("10");
        verify(userMapper).updateById(any(UserEntity.class));
        verify(userSettingMapper, never()).upsert(any(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean(), anyBoolean());
    }

    /**
     * 只提交通知补丁 → upsert 合并后的值、不写 {@code user}。
     *
     * @return void；断言失败即补丁未与既有值合并（丢字段）
     */
    @Test
    @DisplayName("更新：只改通知 → upsert 合并值，不写 user")
    void updateNotifyOnlyMergesWithExisting() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("3"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(settingRow(1, 1, 1, 1));

        SettingsResponse response = service.update(USER_ID,
                new SettingsUpdateRequest(new SettingsUpdateRequest.NotifyPatch(false, null, null, null),
                        null, null));

        assertThat(response.notifySettings().enabled()).isFalse();
        assertThat(response.notifySettings().system()).isTrue();
        verify(userSettingMapper).upsert(USER_ID, false, true, true, true, true);
        verify(userMapper, never()).updateById(any(UserEntity.class));
    }

    /**
     * 只提交隐私补丁（关闭个性化排序）→ upsert 合并，其余开关不动。
     *
     * @return void；断言失败即「关闭个性化推荐」未落库（算法推荐可关闭义务失效）
     */
    @Test
    @DisplayName("更新：关闭个性化排序 → upsert 写入 0，其余保持")
    void updatePersonalizedOnly() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("3"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(settingRow(1, 1, 1, 1));

        SettingsResponse response = service.update(USER_ID,
                new SettingsUpdateRequest(null, null,
                        new SettingsUpdateRequest.PrivacyPatch(false)));

        assertThat(response.privacy().personalizedRecommend()).isFalse();
        assertThat(response.notifySettings().enabled()).isTrue();
        assertThat(response.defaultRadius()).isEqualTo("3");
        verify(userSettingMapper).upsert(USER_ID, true, true, true, true, false);
        verify(userMapper, never()).updateById(any(UserEntity.class));
    }

    /**
     * {@code default_radius} 非 {@code RadiusEnum} → {@code 40001}，不写任何表。
     *
     * @return void；断言失败即非法半径落库
     */
    @Test
    @DisplayName("更新：半径非法 → 40001 且不写")
    void updateInvalidRadius() {
        when(userMapper.selectById(USER_ID)).thenReturn(user("3"));
        when(userSettingMapper.selectByUserId(USER_ID)).thenReturn(null);

        assertThatThrownBy(() -> service.update(USER_ID,
                new SettingsUpdateRequest(null, "999", null)))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isSameAs(ErrorCode.PARAM_INVALID));
        verify(userMapper, never()).updateById(any(UserEntity.class));
        verify(userSettingMapper, never()).upsert(any(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean(), anyBoolean());
    }

    /**
     * 响应 JSON 键名钉死契约（含嵌套 {@code notify} / {@code privacy}）。
     *
     * @throws Exception JSON 处理失败（测试环境缺陷）
     */
    @Test
    @DisplayName("响应 JSON 键名与契约逐字一致")
    void responseJsonKeysMatchContract() throws Exception {
        SettingsResponse response = new SettingsResponse(
                new SettingsResponse.NotifySettings(true, true, false, true),
                "5",
                new SettingsResponse.PrivacySettings("transit_only", true));

        JsonNode root = new ObjectMapper().readTree(new ObjectMapper().writeValueAsString(response));

        assertThat(fieldNamesOf(root)).containsExactlyInAnyOrder("notify", "default_radius", "privacy");
        assertThat(fieldNamesOf(root.get("notify")))
                .containsExactlyInAnyOrder("enabled", "system", "interaction", "cert");
        assertThat(fieldNamesOf(root.get("privacy")))
                .containsExactlyInAnyOrder("contact_display", "personalized_recommend");
    }

    /**
     * 取 JSON 对象字段名（用于键名契约断言）。
     *
     * @param node JSON 对象节点
     * @return {@link List} 字段名
     */
    private static List<String> fieldNamesOf(JsonNode node) {
        List<String> names = new ArrayList<>();
        node.fieldNames().forEachRemaining(names::add);
        return names;
    }

    /**
     * 构造用户实体夹具。
     *
     * @param defaultRadius 默认检索半径档位
     * @return {@link UserEntity}
     */
    private static UserEntity user(String defaultRadius) {
        UserEntity user = new UserEntity();
        user.setId(USER_ID);
        user.setDefaultRadius(defaultRadius);
        return user;
    }

    /**
     * 构造 {@code user_setting} 行夹具（列名与 {@code UserSettingMapper.xml} 出参一致）。
     *
     * @param enabled     总开关（0/1）
     * @param system      系统通道（0/1）
     * @param interaction 互动通道（0/1）
     * @param cert        认证通道（0/1）
     * @return {@link Map} 列名 → 值
     */
    private static Map<String, Object> settingRow(int enabled, int system, int interaction, int cert) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("notify_enabled", enabled);
        row.put("notify_system", system);
        row.put("notify_interaction", interaction);
        row.put("notify_cert", cert);
        row.put("personalized_recommend", 1);
        return row;
    }
}
