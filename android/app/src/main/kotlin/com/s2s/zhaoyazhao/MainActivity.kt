package com.s2s.zhaoyazhao

import android.os.Debug
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
 */
class MainActivity : FlutterActivity() {

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
    }

    companion object {
        /** 峰值内存采集通道名（与 Dart 端 MemPeakReader.channelName 同名）。 */
        private const val CHANNEL_MEM_PEAK = "com.s2s.zhaoyazhao/mem_peak"

        /** 采集方法名。 */
        private const val METHOD_GET_MEM_PEAK_MB = "getMemPeakMb"
    }
}
