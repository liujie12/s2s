package com.s2s.server.notify;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.auth.PushPlatform;
import com.s2s.server.auth.entity.DeviceEntity;
import com.s2s.server.auth.mapper.DeviceMapper;
import com.s2s.server.notify.mapper.NotificationMapper;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link PushDispatchService} 下发编排测试（[B2-2]；PRD §6.14 / §12.3）。
 *
 * <p>守的是什么：编排里有三条**只在降级时才走**的分支，它们一旦写错，正常路径照样跑通、
 * 编译与手测都不会暴露：
 * <ol>
 *   <li>站内通知必须**先写**（推送可失败，站内是兜底）；</li>
 *   <li>「无发送器 / 无通道」的设备不得占用配额 —— 否则阶段 1（凭据未办、路由表为空）
 *       会把用户的 10 条配额白烧光，而用户什么推送都收不到；</li>
 *   <li>配额按**消息**而非**设备**计（PRD 口径是「单用户每日接收推送 ≤10 条」）。</li>
 * </ol></p>
 */
class PushDispatchServiceTest {

    /** 测试用自然日（固定值，避开真实时钟）。 */
    private static final LocalDate TODAY = LocalDate.of(2026, 10, 12);

    /** 测试用接收者。 */
    private static final Long USER_ID = 7L;

    /** mock 的通知写入 Mapper。 */
    private NotificationMapper notificationMapper;

    /** mock 的设备读 Mapper。 */
    private DeviceMapper deviceMapper;

    /** mock 的配额闸。 */
    private PushQuotaGate quotaGate;

    /** mock 的发送器路由表。 */
    private PushSenderRegistry senderRegistry;

    /** 被测下发编排。 */
    private PushDispatchService dispatchService;

    /**
     * 每测前置：装配全部 mock 依赖与被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        notificationMapper = mock(NotificationMapper.class);
        deviceMapper = mock(DeviceMapper.class);
        quotaGate = mock(PushQuotaGate.class);
        senderRegistry = mock(PushSenderRegistry.class);
        dispatchService = new PushDispatchService(
                notificationMapper, deviceMapper, quotaGate, senderRegistry);
    }

    /**
     * 正常路径：站内写入 + 配额通过 + 单设备受理。
     *
     * @return void
     */
    @Test
    void dispatchWritesStationNotificationAndPushes() {
        PushSender sender = mock(PushSender.class);
        when(deviceMapper.selectList(any())).thenReturn(List.of(device(1L, "tok-1", "mi")));
        when(senderRegistry.forPlatform(PushPlatform.MI)).thenReturn(Optional.of(sender));
        when(quotaGate.tryConsume(eq(USER_ID), any(LocalDate.class))).thenReturn(true);
        when(sender.send(eq("tok-1"), any(PushMessage.class))).thenReturn(true);

        PushDispatchResult result = dispatchService.dispatch(
                USER_ID, NotifyType.INTERACTION, "有人联系了你的发布", "点开看看", 1001L);

        assertThat(result.stationNotified()).isTrue();
        assertThat(result.quotaAvailable()).isTrue();
        assertThat(result.attempted()).isEqualTo(1);
        assertThat(result.accepted()).isEqualTo(1);
        verify(notificationMapper).insertNotification(eq(USER_ID), eq("interaction"),
                anyString(), anyString(), eq(1001L), any(LocalDateTime.class));
        verify(sender).send(eq("tok-1"), any(PushMessage.class));
    }

    /**
     * 配额超限：站内照写，**不下发**（PRD §12.3「超出仅落站内通知不下发」）。
     *
     * @return void
     */
    @Test
    void dispatchSkipsPushWhenQuotaRejected() {
        PushSender sender = mock(PushSender.class);
        when(deviceMapper.selectList(any())).thenReturn(List.of(device(1L, "tok-1", "mi")));
        when(senderRegistry.forPlatform(PushPlatform.MI)).thenReturn(Optional.of(sender));
        when(quotaGate.tryConsume(eq(USER_ID), any(LocalDate.class))).thenReturn(false);

        PushDispatchResult result = dispatchService.dispatch(
                USER_ID, NotifyType.SYSTEM, "标题", null, null);

        assertThat(result.stationNotified()).isTrue();
        assertThat(result.quotaAvailable()).isFalse();
        assertThat(result.attempted()).isZero();
        assertThat(result.accepted()).isZero();
        verify(notificationMapper).insertNotification(anyLong(), anyString(), anyString(),
                any(), any(), any(LocalDateTime.class));
        verify(sender, never()).send(anyString(), any(PushMessage.class));
    }

    /**
     * 该通道尚无发送器实现（阶段 1 实况）：只写站内，且**不消耗配额**。
     *
     * @return void
     */
    @Test
    void dispatchSkipsPushAndQuotaWhenNoSenderRegistered() {
        when(deviceMapper.selectList(any())).thenReturn(List.of(device(1L, "tok-1", "mi")));
        when(senderRegistry.forPlatform(PushPlatform.MI)).thenReturn(Optional.empty());

        PushDispatchResult result = dispatchService.dispatch(
                USER_ID, NotifyType.SYSTEM, "标题", null, null);

        assertThat(result.stationNotified()).isTrue();
        assertThat(result.quotaAvailable()).isFalse();
        assertThat(result.attempted()).isZero();
        verify(quotaGate, never()).tryConsume(anyLong(), any(LocalDate.class));
    }

    /**
     * 设备通道未知（{@code push_platform} 为空，老行）：过滤掉，同样不占配额。
     *
     * @return void
     */
    @Test
    void dispatchFiltersDevicesWithUnknownPlatform() {
        when(deviceMapper.selectList(any())).thenReturn(List.of(device(1L, "tok-1", null)));

        PushDispatchResult result = dispatchService.dispatch(
                USER_ID, NotifyType.SYSTEM, "标题", null, null);

        assertThat(result.attempted()).isZero();
        verify(quotaGate, never()).tryConsume(anyLong(), any(LocalDate.class));
    }

    /**
     * 厂商未受理（invalid token 等）：{@code attempted=1} 但 {@code accepted=0}，
     * 且**不因单台失败中断** —— 同批其他设备仍应被尝试。
     *
     * @return void
     */
    @Test
    void dispatchCountsAttemptedButNotAcceptedWhenSenderRejects() {
        PushSender sender = mock(PushSender.class);
        when(deviceMapper.selectList(any()))
                .thenReturn(List.of(device(1L, "tok-1", "mi"), device(2L, "tok-2", "mi")));
        when(senderRegistry.forPlatform(PushPlatform.MI)).thenReturn(Optional.of(sender));
        when(quotaGate.tryConsume(eq(USER_ID), any(LocalDate.class))).thenReturn(true);
        when(sender.send(eq("tok-1"), any(PushMessage.class))).thenReturn(false);
        when(sender.send(eq("tok-2"), any(PushMessage.class))).thenReturn(true);

        PushDispatchResult result = dispatchService.dispatch(
                USER_ID, NotifyType.SYSTEM, "标题", null, null);

        assertThat(result.attempted()).isEqualTo(2);
        assertThat(result.accepted()).isEqualTo(1);
        verify(quotaGate).tryConsume(eq(USER_ID), any(LocalDate.class));
    }

    /**
     * 构造一台设备行。
     *
     * @param id           设备 ID
     * @param token        推送 token
     * @param pushPlatform 推送通道线值（可为 null 表示老行）
     * @return {@link DeviceEntity} 设备行
     */
    private DeviceEntity device(Long id, String token, String pushPlatform) {
        DeviceEntity device = new DeviceEntity();
        device.setId(id);
        device.setUserId(USER_ID);
        device.setPushToken(token);
        device.setPushPlatform(pushPlatform);
        return device;
    }
}
