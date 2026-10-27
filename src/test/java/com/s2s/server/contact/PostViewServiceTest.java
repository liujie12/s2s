package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.mapper.PostViewMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DuplicateKeyException;

/**
 * {@link PostViewService} 行为测试（U5 / KTD6 / KTD8）。
 *
 * <p>覆盖四类易错口径：① 人/天去重（同一键同日只计 1）；② 跨日重新计数；
 * ③ 登录时合并当日设备行（净增量 0 时不写日计数）；④ 作者排除与入参校验。</p>
 *
 * <p>纯单元测试：Mapper 以 Mockito 替身注入，不连库、不起 Spring 上下文。</p>
 */
class PostViewServiceTest {

    /** 帖子作者 ID。 */
    private static final Long AUTHOR_ID = 7L;

    /** 浏览者 ID。 */
    private static final Long VIEWER_ID = 3003L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 1001L;

    /** 合法设备号（UUID v4，与 X-Device-Id 生成规则一致）。 */
    private static final String DEVICE_ID = "11111111-1111-4111-8111-111111111111";

    /** 业务日（Asia/Shanghai 2026-10-27 10:00）。 */
    private static final LocalDate DAY = LocalDate.of(2026, 10, 27);

    /** 固定时钟：业务日 = {@link #DAY}。 */
    private static final Clock CLOCK =
            Clock.fixed(Instant.parse("2026-10-27T02:00:00Z"), RateLimitThresholds.ZONE);

    /** 游客去重键。 */
    private static final String DEVICE_KEY = "device:" + DEVICE_ID;

    /** 登录用户去重键。 */
    private static final String USER_KEY = "user:" + VIEWER_ID;

    private PostViewMapper mapper;
    private PostViewService service;

    @BeforeEach
    void setUp() {
        mapper = mock(PostViewMapper.class);
        service = new PostViewService(mapper, CLOCK);
        when(mapper.selectPostOwner(POST_ID)).thenReturn(AUTHOR_ID);
    }

    /**
     * 首次上报：插入明细 + 日计数 +1。
     */
    @Test
    @DisplayName("首次上报：明细 1 行，日计数 +1")
    void firstReportInsertsRowAndIncrementsDaily() {
        when(mapper.countView(POST_ID, DEVICE_KEY, DAY)).thenReturn(0);
        when(mapper.insertView(POST_ID, DEVICE_KEY, DAY)).thenReturn(1);

        service.report(null, POST_ID, DEVICE_ID);

        verify(mapper).insertView(POST_ID, DEVICE_KEY, DAY);
        verify(mapper).upsertDaily(POST_ID, DAY, 1);
    }

    /**
     * 同日重复上报：不插明细、不动日计数。
     */
    @Test
    @DisplayName("同日重复上报：不新增明细、不写日计数")
    void sameDayRepeatIsDeduped() {
        when(mapper.countView(POST_ID, DEVICE_KEY, DAY)).thenReturn(1);

        service.report(null, POST_ID, DEVICE_ID);

        verify(mapper, never()).insertView(any(), anyString(), any());
        verify(mapper, never()).upsertDaily(any(), any(), anyInt());
    }

    /**
     * 次日再上报：视为新的一次浏览。
     */
    @Test
    @DisplayName("次日再上报：换新业务日重新计数")
    void nextDayCountsAgain() {
        LocalDate nextDay = DAY.plusDays(1);
        PostViewService nextDayService = new PostViewService(
                mapper,
                Clock.fixed(Instant.parse("2026-10-28T02:00:00Z"), RateLimitThresholds.ZONE));
        when(mapper.countView(POST_ID, DEVICE_KEY, nextDay)).thenReturn(0);
        when(mapper.insertView(POST_ID, DEVICE_KEY, nextDay)).thenReturn(1);

        nextDayService.report(null, POST_ID, DEVICE_ID);

        verify(mapper).upsertDaily(POST_ID, nextDay, 1);
    }

    /**
     * 先游客后登录同一设备：删当日设备行（-1）再插用户行（+1），净增量为 0。
     */
    @Test
    @DisplayName("先游客后登录同设备：合并后只计 1（净增量 0 不写日计数）")
    void loginMergesSameDayDeviceRow() {
        when(mapper.deleteView(POST_ID, DEVICE_KEY, DAY)).thenReturn(1);
        when(mapper.countView(POST_ID, USER_KEY, DAY)).thenReturn(0);
        when(mapper.insertView(POST_ID, USER_KEY, DAY)).thenReturn(1);

        service.report(VIEWER_ID, POST_ID, DEVICE_ID);

        verify(mapper).deleteView(POST_ID, DEVICE_KEY, DAY);
        verify(mapper, never()).upsertDaily(any(), any(), anyInt());
    }

    /**
     * 登录用户带设备号但当日无游客行：只插用户行，日计数 +1。
     */
    @Test
    @DisplayName("登录上报（当日无设备行）：日计数 +1")
    void loginWithoutDeviceRowIncrementsOnce() {
        when(mapper.deleteView(POST_ID, DEVICE_KEY, DAY)).thenReturn(0);
        when(mapper.countView(POST_ID, USER_KEY, DAY)).thenReturn(0);
        when(mapper.insertView(POST_ID, USER_KEY, DAY)).thenReturn(1);

        service.report(VIEWER_ID, POST_ID, DEVICE_ID);

        verify(mapper).upsertDaily(POST_ID, DAY, 1);
    }

    /**
     * 登录用户无设备号：跳过合并，直接按用户键去重。
     */
    @Test
    @DisplayName("登录用户无设备号：跳过合并，按用户键计数")
    void loginWithoutDeviceIdSkipsMerge() {
        when(mapper.countView(POST_ID, USER_KEY, DAY)).thenReturn(0);
        when(mapper.insertView(POST_ID, USER_KEY, DAY)).thenReturn(1);

        service.report(VIEWER_ID, POST_ID, null);

        verify(mapper, never()).deleteView(any(), anyString(), any());
        verify(mapper).upsertDaily(POST_ID, DAY, 1);
    }

    /**
     * 作者本人浏览：直接返回，两表都不写。
     */
    @Test
    @DisplayName("作者上报：两表都不写，正常返回")
    void authorReportIsIgnored() {
        service.report(AUTHOR_ID, POST_ID, DEVICE_ID);

        verify(mapper, never()).countView(any(), anyString(), any());
        verify(mapper, never()).insertView(any(), anyString(), any());
        verify(mapper, never()).upsertDaily(any(), any(), anyInt());
    }

    /**
     * 游客缺设备号：{@code 40001}（无法去重，不能盲计）。
     */
    @Test
    @DisplayName("游客缺 X-Device-Id：40001")
    void guestWithoutDeviceIdIsRejected() {
        assertThatThrownBy(() -> service.report(null, POST_ID, null))
                .isInstanceOfSatisfying(BizException.class,
                        e -> assertThat(e.getErrorCode()).isEqualTo(ErrorCode.PARAM_INVALID));
    }

    /**
     * 设备号格式非法（非 UUID v4）按缺头处理：游客同样 {@code 40001}。
     */
    @Test
    @DisplayName("设备号非 UUID v4：按缺头处理（40001）")
    void guestWithMalformedDeviceIdIsRejected() {
        assertThatThrownBy(() -> service.report(null, POST_ID, "not-a-uuid"))
                .isInstanceOfSatisfying(BizException.class,
                        e -> assertThat(e.getErrorCode()).isEqualTo(ErrorCode.PARAM_INVALID));
    }

    /**
     * 帖子不存在：{@code 41001}，且不写任何明细。
     */
    @Test
    @DisplayName("帖子不存在：41001 且不写明细")
    void missingPostIsRejected() {
        when(mapper.selectPostOwner(404L)).thenReturn(null);

        assertThatThrownBy(() -> service.report(VIEWER_ID, 404L, DEVICE_ID))
                .isInstanceOfSatisfying(BizException.class,
                        e -> assertThat(e.getErrorCode()).isEqualTo(ErrorCode.POST_GONE));

        verify(mapper, never()).insertView(eq(404L), anyString(), any());
    }

    /**
     * 并发下唯一键冲突：按「已去过重」处理，不重复加计数。
     */
    @Test
    @DisplayName("唯一键冲突：按已去过重处理，不重复计数")
    void duplicateKeyRaceIsTreatedAsDeduped() {
        when(mapper.countView(POST_ID, DEVICE_KEY, DAY)).thenReturn(0);
        when(mapper.insertView(POST_ID, DEVICE_KEY, DAY))
                .thenThrow(new DuplicateKeyException("uk_post_viewer_day"));

        service.report(null, POST_ID, DEVICE_ID);

        verify(mapper, never()).upsertDaily(any(), any(), anyInt());
    }
}
