package com.s2s.zhaoyazhao.badge

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android 桌面角标平台通道（R11 / KTD13）。
 *
 * Dart 侧调用点见 `lib/core/badge/app_badge.dart`：只下发未读总数（0＝清除），
 * 上限 99 由 Dart 侧按 `NfrChat.unreadBadgeMax` 折算后传入，本类不再自行定义上限。
 *
 * 实现纪律（KTD13「原生自研、不引三方插件」）：
 * - 直接向各厂商启动器广播角标变更，不申请额外权限、不常驻服务；
 * - 启动器不支持数字角标（或广播抛异常）时**降级为红点（值 1）**，并在返回结果里
 *   标注降级原因，Dart 侧只记录、不向用户报错；
 * - 清除角标（count=0）与设置数字走同一组广播，只是数值/文本为空。
 *
 * 已覆盖的厂商广播（均为公开接口）：
 * - 小米 `android.intent.action.APPLICATION_MESSAGE_UPDATE`
 * - 华为 / 三星 `android.intent.action.BADGE_COUNT_UPDATE`
 * - 索尼 `com.sonyericsson.home.action.UPDATE_BADGE`
 * 其余厂商（OPPO / vivo 等）无公开角标接口，按「不支持」走红点降级。
 *
 * @param context 宿主上下文（应用级即可，不需要 Activity）。
 */
class BadgeMethodHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    /**
     * 处理 Dart 侧方法调用。
     *
     * @param call 方法名与参数（`setBadge` + `count`）。
     * @param result 异步回执；返回 `{applied, degraded}` 映射。
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_SET_BADGE) {
            result.notImplemented()
            return
        }
        val count = call.argument<Int>("count") ?: 0
        result.success(apply(count))
    }

    /**
     * 下发角标并构造回执。
     *
     * @param count 未读总数（0＝清除；上限由 Dart 侧折算）。
     * @return 回执映射：`applied` 是否生效，`degraded` 降级原因（null＝数字角标）。
     */
    internal fun apply(count: Int): Map<String, Any?> {
        if (count <= 0) {
            broadcastBadge(0)
            return mapOf(KEY_APPLIED to true, KEY_DEGRADED to null)
        }
        if (broadcastBadge(count)) {
            return mapOf(KEY_APPLIED to true, KEY_DEGRADED to null)
        }
        // 数字角标不可用 → 降级红点（值 1），与「不支持数字的启动器降级为小红点」一致。
        val dotApplied = broadcastBadge(DOT_VALUE)
        val reason = if (dotApplied) DEGRADED_DOT else DEGRADED_UNSUPPORTED
        return mapOf(KEY_APPLIED to dotApplied, KEY_DEGRADED to reason)
    }

    /**
     * 向已安装的厂商启动器广播角标值。
     *
     * @param count 角标数字（0＝清除）。
     * @return 是否至少向一个启动器发出广播（false＝无可用厂商接口或发送异常）。
     */
    private fun broadcastBadge(count: Int): Boolean {
        val component = launchComponent() ?: return false
        var sent = false
        try {
            if (isInstalled(PKG_XIAOMI)) {
                sendXiaomi(component, count)
                sent = true
            }
            if (isInstalled(PKG_HUAWEI)) {
                sendBadgeCountUpdate(PKG_HUAWEI, component, count)
                sent = true
            }
            if (isInstalled(PKG_SAMSUNG)) {
                sendBadgeCountUpdate(PKG_SAMSUNG, component, count)
                sent = true
            }
            val sonyPackage = SONY_PACKAGES.firstOrNull { isInstalled(it) }
            if (sonyPackage != null) {
                sendSony(sonyPackage, component, count)
                sent = true
            }
        } catch (e: Exception) {
            // 厂商接口在个别 ROM 上会抛 SecurityException / IllegalArgumentException：
            // 一律当作「不支持数字角标」，由调用方降级，不让角标失败影响主链。
            return false
        }
        return sent
    }

    /**
     * 取应用自身的启动组件（角标广播需要「包名 + 启动 Activity 类名」）。
     *
     * @return 启动组件；无启动入口时为 null。
     */
    private fun launchComponent(): ComponentName? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        return intent?.component
    }

    /**
     * 判断某启动器包是否已安装（角标广播只对对应厂商启动器有意义）。
     *
     * @param packageName 启动器包名。
     * @return 是否已安装。
     */
    private fun isInstalled(packageName: String): Boolean {
        return try {
            context.packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * 小米角标广播。
     *
     * @param component 应用启动组件。
     * @param count 角标数字（0＝清除，文本传空串）。
     */
    private fun sendXiaomi(component: ComponentName, count: Int) {
        val intent = Intent(ACTION_XIAOMI_BADGE)
        intent.putExtra(EXTRA_XIAOMI_COMPONENT, "${component.packageName}/${component.className}")
        intent.putExtra(EXTRA_XIAOMI_MESSAGE, if (count <= 0) "" else count.toString())
        context.sendBroadcast(intent)
    }

    /**
     * 华为 / 三星角标广播（两者共用同一 action 与 extra 名）。
     *
     * @param launcherPackage 目标启动器包名。
     * @param component 应用启动组件。
     * @param count 角标数字（0＝清除）。
     */
    private fun sendBadgeCountUpdate(
        launcherPackage: String,
        component: ComponentName,
        count: Int,
    ) {
        val intent = Intent(ACTION_BADGE_COUNT_UPDATE)
        intent.setPackage(launcherPackage)
        intent.putExtra(EXTRA_BADGE_COUNT, count)
        intent.putExtra(EXTRA_BADGE_PACKAGE, component.packageName)
        intent.putExtra(EXTRA_BADGE_CLASS, component.className)
        context.sendBroadcast(intent)
    }

    /**
     * 索尼角标广播。
     *
     * @param launcherPackage 目标启动器包名。
     * @param component 应用启动组件。
     * @param count 角标数字（0＝清除，SHOW_MESSAGE 置 false）。
     */
    private fun sendSony(launcherPackage: String, component: ComponentName, count: Int) {
        val intent = Intent(ACTION_SONY_BADGE)
        intent.setPackage(launcherPackage)
        intent.putExtra(EXTRA_SONY_SHOW, count > 0)
        intent.putExtra(EXTRA_SONY_COUNT, count)
        intent.putExtra(EXTRA_SONY_PACKAGE, component.packageName)
        intent.putExtra(EXTRA_SONY_CLASS, component.className)
        context.sendBroadcast(intent)
    }

    companion object {
        /** 通道名（与 Dart 侧 `AppBadge.channelName` 同名）。 */
        const val CHANNEL_NAME = "com.s2s.zhaoyazhao/badge"

        /** 下发角标方法名（与 Dart 侧 `AppBadge.methodSetBadge` 同名）。 */
        const val METHOD_SET_BADGE = "setBadge"

        /** 回执键：是否生效。 */
        private const val KEY_APPLIED = "applied"

        /** 回执键：降级原因（null＝数字角标）。 */
        private const val KEY_DEGRADED = "degraded"

        /** 降级原因：启动器只能显示红点。 */
        private const val DEGRADED_DOT = "dot_fallback"

        /** 降级原因：无可用厂商接口。 */
        private const val DEGRADED_UNSUPPORTED = "unsupported_launcher"

        /** 降级红点的值（只表示「有未读」，不带条数）。 */
        private const val DOT_VALUE = 1

        /**
         * 后台收到通知时设置「有未读」角标（红点语义，值 1）。
         *
         * 调用方是小米推送的 `onNotificationMessageArrived`：此时 Dart 侧不在运行，
         * 拿不到精确未读数，只点亮红点；用户回到前台后由 Dart 侧用
         * `unread-summary` 的精确值覆盖（或清零）。
         *
         * @param context 任意上下文（推送回调给的是应用级 Context）。
         */
        fun applyUnreadDot(context: Context) {
            BadgeMethodHandler(context).apply(DOT_VALUE)
        }

        /** 小米启动器包名。 */
        private const val PKG_XIAOMI = "com.miui.home"

        /** 华为启动器包名。 */
        private const val PKG_HUAWEI = "com.huawei.android.launcher"

        /** 三星启动器包名。 */
        private const val PKG_SAMSUNG = "com.sec.android.app.launcher"

        /** 索尼启动器包名（新旧两代）。 */
        private val SONY_PACKAGES = listOf("com.sonyericsson.home", "com.sonymobile.home")

        /** 小米角标 action。 */
        private const val ACTION_XIAOMI_BADGE = "android.intent.action.APPLICATION_MESSAGE_UPDATE"

        /** 小米角标 extra：组件名。 */
        private const val EXTRA_XIAOMI_COMPONENT =
            "android.intent.extra.update_application_component_name"

        /** 小米角标 extra：角标文本。 */
        private const val EXTRA_XIAOMI_MESSAGE =
            "android.intent.extra.update_application_message_text"

        /** 华为 / 三星角标 action。 */
        private const val ACTION_BADGE_COUNT_UPDATE = "android.intent.action.BADGE_COUNT_UPDATE"

        /** 华为 / 三星角标 extra：数字。 */
        private const val EXTRA_BADGE_COUNT = "badge_count"

        /** 华为 / 三星角标 extra：包名。 */
        private const val EXTRA_BADGE_PACKAGE = "badge_count_package_name"

        /** 华为 / 三星角标 extra：启动类名。 */
        private const val EXTRA_BADGE_CLASS = "badge_count_class_name"

        /** 索尼角标 action。 */
        private const val ACTION_SONY_BADGE = "com.sonyericsson.home.action.UPDATE_BADGE"

        /** 索尼角标 extra：是否显示。 */
        private const val EXTRA_SONY_SHOW =
            "com.sonyericsson.home.intent.extra.badge.SHOW_MESSAGE"

        /** 索尼角标 extra：数字。 */
        private const val EXTRA_SONY_COUNT =
            "com.sonyericsson.home.intent.extra.badge.MESSAGE_COUNT"

        /** 索尼角标 extra：包名。 */
        private const val EXTRA_SONY_PACKAGE =
            "com.sonyericsson.home.intent.extra.badge.PACKAGE_NAME"

        /** 索尼角标 extra：启动类名。 */
        private const val EXTRA_SONY_CLASS =
            "com.sonyericsson.home.intent.extra.badge.ACTIVITY_NAME"
    }
}
