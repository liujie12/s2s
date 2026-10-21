package com.s2s.zhaoyazhao.push

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.s2s.zhaoyazhao.BuildConfig
import com.xiaomi.mipush.sdk.MiPushClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 推送平台通道处理器（B2-2 阶段 2，小米通道）。
 *
 * Dart 侧调用点见 `lib/features/notify/push_service.dart`；本类只做三件事：
 * 触发厂商注册、把 token/点击事件回传、申请 Android 13+ 通知权限。
 *
 * 通道方法：
 * - `register`：调用 [MiPushClient.registerPush]；返回 `ok` / `not_configured`。
 * - `getToken`：返回已缓存的 regId（未注册或未回包时为 null）。
 * - `requestPermission`：Android 13+ 申请 POST_NOTIFICATIONS；返回是否已授权。
 * - `getInitialClick`：取「App 未启动时点击通知」暂存的内容（读取后不清除）。
 *
 * 回调（原生 → Dart）：`onToken`、`onClick`。
 *
 * @param activity 宿主 Activity（注册推送与申请权限都需要 Context）。
 */
class PushMethodHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /**
     * 绑定通道并登记为当前活动处理器（供 [MiPushReceiver] 从任意上下文回传事件）。
     *
     * @param channel 已创建的 Flutter MethodChannel。
     */
    fun attach(channel: MethodChannel) {
        this.channel = channel
        active = this
    }

    /**
     * 处理 Dart 侧方法调用。
     *
     * @param call 方法名与参数。
     * @param result 异步回执。
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_REGISTER -> registerPush(result)
            METHOD_GET_TOKEN -> result.success(readToken(activity))
            METHOD_REQUEST_PERMISSION -> requestNotificationPermission(result)
            METHOD_GET_INITIAL_CLICK -> result.success(readStoredClick(activity))
            else -> result.notImplemented()
        }
    }

    /**
     * 触发小米推送注册。
     *
     * 凭据为空时返回 `not_configured`（Dart 侧静默跳过，不视为错误）；
     * 否则发起注册，regId 通过 [MiPushReceiver.onReceiveRegisterResult] 异步回传。
     *
     * @param result 异步回执。
     */
    private fun registerPush(result: MethodChannel.Result) {
        val appId = BuildConfig.MIPUSH_APP_ID
        val appKey = BuildConfig.MIPUSH_APP_KEY
        if (appId.isBlank() || appKey.isBlank()) {
            result.success(STATUS_NOT_CONFIGURED)
            return
        }
        MiPushClient.registerPush(activity.applicationContext, appId, appKey)
        result.success(STATUS_OK)
    }

    /**
     * 申请 Android 13+ 通知权限（低版本或已授权直接返回 true）。
     *
     * @param result 异步回执；结果在 [onPermissionResult] 中返回。
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        // 未配置厂商凭据时不弹系统权限框：没有可用的推送通道，弹窗只有打扰没有用途
        //（挂账期 `mipush.appId/appKey` 为空，避免提前消耗用户的授权意愿）。
        if (BuildConfig.MIPUSH_APP_ID.isBlank() || BuildConfig.MIPUSH_APP_KEY.isBlank()) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (activity.checkSelfPermission(PERMISSION_POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(arrayOf(PERMISSION_POST_NOTIFICATIONS), REQUEST_CODE_NOTIFICATION)
    }

    /**
     * Activity 权限回调转发（由 MainActivity 调用）。
     *
     * @param granted 用户是否授权。
     */
    fun onPermissionResult(granted: Boolean) {
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /**
     * 向 Dart 回传事件；通道尚未就绪（Flutter 引擎未起）时静默丢弃，由缓存兜底。
     *
     * @param method 事件名（`onToken` / `onClick`）。
     * @param arguments 事件参数。
     */
    fun emit(method: String, arguments: Any?) {
        channel?.invokeMethod(method, arguments)
    }

    companion object {
        /** 通道名（与 Dart 侧 PushService.channelName 同名）。 */
        const val CHANNEL_NAME = "com.s2s.zhaoyazhao/push"

        /** 触发注册。 */
        const val METHOD_REGISTER = "register"

        /** 读取缓存 token。 */
        const val METHOD_GET_TOKEN = "getToken"

        /** 申请通知权限。 */
        const val METHOD_REQUEST_PERMISSION = "requestPermission"

        /** 读取冷启动点击内容。 */
        const val METHOD_GET_INITIAL_CLICK = "getInitialClick"

        /** 原生 → Dart：token 到达。 */
        const val EVENT_TOKEN = "onToken"

        /** 原生 → Dart：通知被点击。 */
        const val EVENT_CLICK = "onClick"

        /** 注册已发起。 */
        const val STATUS_OK = "ok"

        /** 本地未配置 AppId/AppKey。 */
        const val STATUS_NOT_CONFIGURED = "not_configured"

        /** SharedPreferences 文件名。 */
        const val PREFS_NAME = "s2s_push"

        /** regId 存储键。 */
        const val KEY_TOKEN = "mi_reg_id"

        /** 冷启动点击内容存储键。 */
        const val KEY_CLICK = "last_click"

        /** 请求码（固定值，避免与其它权限请求撞码）。 */
        private const val REQUEST_CODE_NOTIFICATION = 4201

        /** Android 13 通知权限常量（低版本系统无此常量，故用字面量）。 */
        private const val PERMISSION_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"

        /** 当前活动处理器；Receiver 通过它回传事件。 */
        @Volatile
        var active: PushMethodHandler? = null
            private set

        /**
         * 读取已缓存 token。
         *
         * @param context 任意上下文。
         * @return regId；未注册时为 null。
         */
        fun readToken(context: Context): String? =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_TOKEN, null)

        /**
         * 写入 token 并回传 Dart。
         *
         * @param context 任意上下文。
         * @param token 厂商下发的 regId。
         */
        fun saveToken(context: Context, token: String) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_TOKEN, token).apply()
            active?.emit(EVENT_TOKEN, token)
        }

        /**
         * 暂存点击内容并回传 Dart。
         *
         * @param context 任意上下文。
         * @param payload 点击消息（content + extras）。
         */
        fun saveClick(context: Context, payload: Map<String, Any?>) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_CLICK, JSONObject(payload).toString()).apply()
            active?.emit(EVENT_CLICK, payload)
        }

        /**
         * 读取上次暂存的点击内容。
         *
         * @param context 任意上下文。
         * @return 点击内容；无记录时为 null。
         */
        fun readStoredClick(context: Context): Map<String, Any?>? {
            val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_CLICK, null) ?: return null
            return runCatching { jsonToMap(JSONObject(raw)) }.getOrNull()
        }

        /**
         * JSONObject 转 Map（仅展开一层，值按字符串处理）。
         *
         * @param json 源对象。
         * @return 键值对。
         */
        private fun jsonToMap(json: JSONObject): Map<String, Any?> {
            val map = mutableMapOf<String, Any?>()
            json.keys().forEach { key -> map[key] = json.optString(key) }
            return map
        }
    }
}
