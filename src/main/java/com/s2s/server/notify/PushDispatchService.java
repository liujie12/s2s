package com.s2s.server.notify;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.auth.PushPlatform;
import com.s2s.server.auth.entity.DeviceEntity;
import com.s2s.server.auth.mapper.DeviceMapper;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.notify.mapper.NotificationMapper;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 推送下发编排（[B2-2]；PRD §6.14 / §12.3；详设 §6 任务 #11 的「下发」半边）。
 *
 * <p><b>职责边界（与本批 B2-3 的分工）</b>：本类只做「**给谁发、发不发得出去**」——
 * 写站内兜底、判配额、按通道选发送器。**「该发给谁」不在本类**（那属 T1 匹配 /
 * 规则加权的产出），调用方决定目标用户与文案后逐条调用 {@link #dispatch}。</p>
 *
 * <p><b>顺序不可换</b>：
 * <ol>
 *   <li>**先写站内通知**（PRD §6.14「站内通知中心兜底」）——推送可能因配额、
 *       无发送器、厂商失败而发不出去，站内必须先落，否则信息直接丢失；</li>
 *   <li>再筛「可下发目标」（有 token + 通道合法 + 有发送器）。**没有可下发目标就不占配额**
 *       ——否则阶段 1（无发送器）会把用户配额白白耗尽；</li>
 *   <li>最后占配额并下发。<b>配额按「消息」而非「设备」计</b>：PRD §6.14 的口径是
 *       「单用户每日**接收**推送 ≤10 条」，一个用户两台设备收到的是同一条消息。</li>
 * </ol></p>
 *
 * <p><b>事务边界</b>：站内写入在事务内（与调用方的业务写同生共死）；推送下发在事务内
 * 但有外部网络调用 —— 厂商受理后若本事务回滚，会出现「推送已发、站内没了」的不一致。
 * 本轮接受该窗口：调用方（B2-3 的定时下发）本身是「读库后发」的独立过程，不与之共事务。</p>
 */
@Service
public class PushDispatchService {

    /** 日志（独立命名，与 {@code RateLimiter} 同考量）。 */
    private static final Logger log = LoggerFactory.getLogger(PushDispatchService.class);

    /** 通知写入 Mapper。 */
    private final NotificationMapper notificationMapper;

    /** 设备读 Mapper（查接收者的推送目标）。 */
    private final DeviceMapper deviceMapper;

    /** 每日配额闸。 */
    private final PushQuotaGate quotaGate;

    /** 通道发送器路由表。 */
    private final PushSenderRegistry senderRegistry;

    /**
     * 构造下发编排。
     *
     * @param notificationMapper 通知写入 Mapper
     * @param deviceMapper       设备读 Mapper
     * @param quotaGate          每日配额闸
     * @param senderRegistry     通道发送器路由表
     */
    public PushDispatchService(NotificationMapper notificationMapper, DeviceMapper deviceMapper,
            PushQuotaGate quotaGate, PushSenderRegistry senderRegistry) {
        this.notificationMapper = notificationMapper;
        this.deviceMapper = deviceMapper;
        this.quotaGate = quotaGate;
        this.senderRegistry = senderRegistry;
    }

    /**
     * 下发一条通知（站内必写 + 尽力推送）。
     *
     * @param userId   接收者 user ID
     * @param type     通知类型（站内与推送同源）
     * @param title    标题（≤64）
     * @param summary  摘要（可空，≤256）
     * @param targetId 关联对象 ID（可空）
     * @return {@link PushDispatchResult} 站内/配额/下发计数，供调用方观测降级
     */
    @Transactional
    public PushDispatchResult dispatch(Long userId, NotifyType type, String title, String summary,
            Long targetId) {
        notificationMapper.insertNotification(userId, type.wire(), title, summary, targetId,
                LocalDateTime.now());

        List<DeviceEntity> targets = loadDispatchableDevices(userId);
        if (targets.isEmpty()) {
            // 无可下发目标（无 token / 通道未知 / 尚无发送器实现）——不占配额。
            return new PushDispatchResult(true, false, 0, 0);
        }

        LocalDate today = RateLimitKeys.today();
        if (!quotaGate.tryConsume(userId, today)) {
            return new PushDispatchResult(true, false, 0, 0);
        }

        PushMessage message = new PushMessage(type, title, summary, targetId);
        int accepted = 0;
        for (DeviceEntity device : targets) {
            // 目标已在 loadDispatchableDevices 里过筛，此处 sender 必存在。
            PushSender sender = senderRegistry
                    .forPlatform(PushPlatform.fromWire(device.getPushPlatform()))
                    .orElseThrow();
            if (sender.send(device.getPushToken(), message)) {
                accepted++;
            }
        }
        return new PushDispatchResult(true, true, targets.size(), accepted);
    }

    /**
     * 取该用户「可下发」的设备（有 token + 通道合法 + 该通道已有发送器实现）。
     *
     * <p>通道未知（{@code push_platform} 为空，即老行或未上报）与尚无发送器的设备被过滤掉
     * ——它们仍能通过站内通知触达，只是不占推送配额。过滤后无目标即不消耗配额，
     * 这条链路让「阶段 1 无发送器」成为**优雅降级**而非「配额被白烧」。</p>
     *
     * @param userId 接收者 user ID
     * @return {@link List} 可下发设备；无则空列表（不含 null）
     */
    private List<DeviceEntity> loadDispatchableDevices(Long userId) {
        List<DeviceEntity> devices = deviceMapper.selectList(new QueryWrapper<DeviceEntity>()
                .eq("user_id", userId)
                .isNotNull("push_token"));
        List<DeviceEntity> targets = new ArrayList<>(devices.size());
        for (DeviceEntity device : devices) {
            PushPlatform platform = PushPlatform.fromWire(device.getPushPlatform());
            if (platform == null) {
                log.warn("设备 {} 无有效推送通道（push_platform={}），仅走站内兜底",
                        device.getId(), device.getPushPlatform());
                continue;
            }
            if (senderRegistry.forPlatform(platform).isEmpty()) {
                log.warn("推送通道 {} 尚无发送器实现（凭据未办），设备 {} 仅走站内兜底",
                        platform.wire(), device.getId());
                continue;
            }
            targets.add(device);
        }
        return targets;
    }
}
