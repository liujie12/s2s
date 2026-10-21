package com.s2s.zhaoyazhao

import android.os.Debug
import com.s2s.zhaoyazhao.push.PushMethodHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 应用主 Activity。
 *
 * 除默认 Flutter 入口外，注册埋点峰值内存采集平台通道（[CHANNEL_MEM_PEAK]，
 * 详细设计 §17.1 `mem_peak_mb`，编码规范缺口 #4）：Android 读 [Debug.MemoryInfo]
 * 的 totalPss（kB）÷1024 得 MB；iOS 侧不注册同名通道，Dart 端捕获
 * MissingPluginException 上报空值（§17.1「iOS 上报空值」）。
 *
 * 另注册推送平台通道（[PushMethodHandler]，B2-2 阶段 2）：小米 token 注册、
 * 点击事件回传、Android 13+ 通知权限申请。
 */
class MainActivity : FlutterActivity() {

    private var pushHandler: PushMethodHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_MEM_PEAK,
        ).setMethodCallHandler { call, result ->
            if (call.method == METHOD_GET_MEM_PEAK_MB) {
                val memoryInfo = Debug.MemoryInfo()
                Debug.getMemoryInfo(memoryInfo)
                result.success(memoryInfo.totalPss / 1024.0)
            } else {
                result.notImplemented()
            }
        }

        val handler = PushMethodHandler(this)
        pushHandler = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PushMethodHandler.CHANNEL_NAME,
        ).apply {
            setMethodCallHandler(handler)
            handler.attach(this)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_NOTIFICATION) {
            pushHandler?.onPermissionResult(
                grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED,
            )
        }
    }

    companion object {
        /** 峰值内存采集通道名（与 Dart 端 MemPeakReader.channelName 同名）。 */
        private const val CHANNEL_MEM_PEAK = "com.s2s.zhaoyazhao/mem_peak"

        /** 采集方法名。 */
        private const val METHOD_GET_MEM_PEAK_MB = "getMemPeakMb"

        /** 通知权限请求码（与 PushMethodHandler 保持一致）。 */
        private const val REQUEST_CODE_NOTIFICATION = 4201
    }
}
