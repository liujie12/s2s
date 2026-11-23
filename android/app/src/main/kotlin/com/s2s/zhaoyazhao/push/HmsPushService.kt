package com.s2s.zhaoyazhao.push

import android.os.Bundle
import com.huawei.hms.push.HmsMessageService
import com.huawei.hms.push.RemoteMessage
import com.s2s.zhaoyazhao.badge.BadgeMethodHandler

/**
 * 华为推送消息服务（P11 华为通道客户端接入）。
 *
 * 职责与 [MiPushReceiver] 对齐：token 落盘并回传 Dart、通知到达时点角标。
 * 通知消息的点击由系统拉起 MainActivity（launchMode=singleTask），不在此处理。
 *
 * 清单注册见 `AndroidManifest.xml` 的 `service` 声明；**必须**带
 * `com.huawei.push.action.MESSAGING_EVENT` 意图过滤器，否则收不到 token 与数据消息。
 */
class HmsPushService : HmsMessageService() {

    /**
     * 新 token 回调（旧签名，HMS Core 低版本走这里）。
     *
     * @param token 华为下发的 Push Token。
     */
    override fun onNewToken(token: String?) {
        persistToken(token)
    }

    /**
     * 新 token 回调（新签名，HMS Core 6+ 走这里）。
     *
     * @param token 华为下发的 Push Token。
     * @param bundle 附加信息（本实现不使用）。
     */
    override fun onNewToken(token: String?, bundle: Bundle?) {
        persistToken(token)
    }

    /**
     * 数据消息到达回调：只点亮桌面角标，正文由系统通知栏负责。
     *
     * App 不在前台时 Dart 层不运行、拿不到精确未读数，这里只置红点（值 1）；
     * 用户回到前台后由 Dart 侧按 `unread-summary` 的精确值覆盖或清零。
     *
     * @param message 到达的消息（本回调不使用其内容）。
     */
    override fun onMessageReceived(message: RemoteMessage?) {
        runCatching { BadgeMethodHandler.applyUnreadDot(this) }
    }

    /**
     * token 落盘并回传 Dart；空值直接丢弃（不上报空 token）。
     *
     * @param token 华为下发的 Push Token，可能为 null。
     */
    private fun persistToken(token: String?) {
        val value = token?.trim().orEmpty()
        if (value.isEmpty()) return
        PushMethodHandler.saveToken(this, PushMethodHandler.CHANNEL_HW, value)
    }
}
