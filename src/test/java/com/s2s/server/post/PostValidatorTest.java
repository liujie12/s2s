package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.category.TemplateService;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.dto.TemplateFieldDto;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.common.moderation.SensitiveWordChecker;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 模板必填判定按字段类型分流测试（计划 U6；KTD4）。
 *
 * <p>守的是「结构化字段只填一半」这一类只会在服务端暴露的缺陷：客户端按
 * 两端坐标禁用主按钮，但存量客户端、旧草稿与服务端口径必须一致 —— 若服务端
 * 把半截对象当成已填，完整度三档与 required_full 会给出一个错误结论。</p>
 */
class PostValidatorTest {

    private static final int CARPOOL_LEAF = 30101;

    private PostValidator validator;
    private TemplateService templateService;

    @BeforeEach
    void setUp() {
        templateService = mock(TemplateService.class);
        validator = new PostValidator(
                mock(SensitiveWordChecker.class),
                mock(MediaService.class),
                mock(CategoryMapper.class),
                mock(CertService.class),
                templateService);
        when(templateService.getByLeaf(CARPOOL_LEAF)).thenReturn(new TemplateDto(
                CARPOOL_LEAF,
                List.of(
                        new TemplateFieldDto("route", "起点 → 终点", "route_pair", true,
                                null, null, null),
                        new TemplateFieldDto("seats", "空座数", "number", true,
                                null, null, null))));
    }

    /**
     * 以 attributes 求 required_full（走 computeDerived 的公开入口）。
     *
     * @param attributes 动态属性
     * @return boolean 必填是否齐全
     */
    private boolean requiredFull(Map<String, Object> attributes) {
        return validator.computeDerived(CARPOOL_LEAF, attributes, false).requiredFull();
    }

    /**
     * 构造一个地点对象。
     *
     * @param lng 经度（可为 null 或非数值，用于缺坐标分支）
     * @param lat 纬度（同上）
     * @return Map 地点
     */
    private Map<String, Object> place(Object lng, Object lat) {
        Map<String, Object> map = new HashMap<>();
        map.put("name", "回龙观");
        if (lng != null) {
            map.put("lng", lng);
        }
        if (lat != null) {
            map.put("lat", lat);
        }
        return map;
    }

    /**
     * 构造起终点对象。
     *
     * @param origin 起点
     * @param destination 终点（null 表示对象里不写该键）
     * @return Map 起终点
     */
    private Map<String, Object> route(Object origin, Object destination) {
        Map<String, Object> map = new HashMap<>();
        if (origin != null) {
            map.put("origin", origin);
        }
        if (destination != null) {
            map.put("destination", destination);
        }
        return map;
    }

    @Test
    void 两端都带数值坐标视为已填() {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("route", route(place(116.337, 40.071), place(116.316, 39.983)));
        attributes.put("seats", "2");

        assertThat(requiredFull(attributes)).isTrue();
    }

    @Test
    void 对象缺终点视为缺失() {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("route", route(place(116.337, 40.071), null));
        attributes.put("seats", "2");

        assertThat(requiredFull(attributes)).isFalse();
    }

    @Test
    void 坐标是字符串或缺失视为缺失() {
        Map<String, Object> stringCoordinate = new HashMap<>();
        stringCoordinate.put("route", route(place("116.337", "40.071"), place(116.316, 39.983)));
        stringCoordinate.put("seats", "2");
        assertThat(requiredFull(stringCoordinate)).isFalse();

        Map<String, Object> missingLat = new HashMap<>();
        missingLat.put("route", route(place(116.337, 40.071), place(116.316, null)));
        missingLat.put("seats", "2");
        assertThat(requiredFull(missingLat)).isFalse();
    }

    @Test
    void 历史字符串形态视为已填() {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("route", "回龙观 → 中关村");
        attributes.put("seats", "2");

        assertThat(requiredFull(attributes)).isTrue();
    }

    @Test
    void attributes为空视为缺失() {
        assertThat(requiredFull(null)).isFalse();
        assertThat(requiredFull(Map.of())).isFalse();
    }

    @Test
    void 非结构化必填字段行为不变() {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("route", route(place(116.337, 40.071), place(116.316, 39.983)));
        // 空座数缺失 / 空白都按缺失
        assertThat(requiredFull(attributes)).isFalse();
        attributes.put("seats", "  ");
        assertThat(requiredFull(attributes)).isFalse();
        attributes.put("seats", "2");
        assertThat(requiredFull(attributes)).isTrue();
    }
}
