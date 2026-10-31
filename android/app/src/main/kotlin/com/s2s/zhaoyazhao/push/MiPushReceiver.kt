package com.s2s.zhaoyazhao.push

import android.content.Context
import com.xiaomi.mipush.sdk.ErrorCode
import com.xiaomi.mipush.sdk.MiPushClient
import com.xiaomi.mipush.sdk.MiPushCommandMessage
import com.xiaomi.mipush.sdk.MiPushMessage
import com.xiaomi.mipush.sdk.PushMessageReceiver

/**
 * 小米推送消息接收器（B2-2 阶段 2）。
 *
 * 必须在主进程（与 `MiPushClient.registerPush` 同进程），否则收不到任何回调；
 * 清单注册见 `AndroidManifest.xml` 的 `receiver` 声明。
 */
class MiPushReceiver : PushMessageReceiver() {

    /**
     * 注册结果回调：成功时把 regId 落盘并回传 Dart。
     *
     * @param context 应用上下文。
     * @param message 小米下发的命令消息。
     */
    override fun onReceiveRegisterResult(context: Context, message: MiPushCommandMessage) {
        if (message.command != MiPushClient.COMMAND_REGISTER) return
        // 7.12.x 的 resultCode 为 Long（旧版为 int），统一按 Int 比较。
        if (message.resultCode.toInt() != ErrorCode.SUCCESS) return
        val regId = message.commandArguments?.firstOrNull() ?: return
        if (regId.isBlank()) return
        PushMethodHandler.saveToken(context, regId)
    }

    /**
     * 通知栏点击回调：暂存内容并回传 Dart（App 在后台/被杀时也能取到）。
     *
     * @param context 应用上下文。
     * @param message 被点击的消息。
     */
    override fun onNotificationMessageClicked(context: Context, message: MiPushMessage) {
        // payload 是服务端 `XiaomiPushSender.dataPayload` 写入的 JSON 字符串
        // （含 landingType / targetId），客户端据此把点击落到会话（R16a）。
        val payload = mutableMapOf<String, Any?>(
            "title" to message.title,
            "content" to message.content,
            "payload" to message.content,
            "extra" to message.extra,
        )
        PushMethodHandler.saveClick(context, payload)
    }
}
