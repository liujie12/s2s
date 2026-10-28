import java.util.Properties
import java.io.FileInputStream
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名配置（条目 [131] 闭合安全阻塞项 B-2）。
// 凭据文件 android/key.properties 已被 .gitignore 忽略，绝不入库：
// 正式签名证书泄露等于应用可被伪造，且证书一经启用不可更换（上架前置手册 P7）。
// 文件缺失时各字段为 null，assembleRelease 会在签名阶段直接失败（fail-closed）——
// 刻意不做「缺文件就回退 debug 签名」的兜底，那正是 B-2 要消除的形态。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// 小米推送客户端凭据（B2-2 阶段 2）。
// 与 key.properties 同口径：本地凭据文件不入库，缺失时为空串 ——
// 原生侧据此判定「未配置」并跳过注册，不崩溃也不伪造 token。
// 键名：mipush.appId / mipush.appKey（写在 android/local.properties，随 Flutter 默认 gitignore）。
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    FileInputStream(localPropertiesFile).use { localProperties.load(it) }
}
val miPushAppId = localProperties.getProperty("mipush.appId") ?: ""
val miPushAppKey = localProperties.getProperty("mipush.appKey") ?: ""

// 小米推送 SDK 为纯 AAR（官方下载包，无 Maven 坐标），直接用文件依赖引入本地 libs。
// 不用 flatDir：空 group 的 flatDir 坐标会让 AGP 的 lint（lintVitalAnalyzeRelease）崩溃
// （Illegal char <"> at index 8: group = ""），导致 release 出包失败。

android {
    namespace = "com.s2s.zhaoyazhao"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // BuildConfig 默认关闭（AGP 8），推送凭据需以编译期常量注入原生侧，故显式开启。
    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // 开发期包名：正式包名依赖 P2 企业域名主体（未办理），故先用 .dev 后缀申请高德开发 Key。
        // P2/P3 落地后改为正式包名并同步重申 Key —— 替换点仅此一处（说明文档条目 [62]）。
        // 须与高德控制台 Key 绑定的 Package 完全一致，否则报 INVALID_USER_SCODE。
        applicationId = "com.s2s.zhaoyazhao.dev"
        // minSdk 24：高德 SDK 下限为 21，但 Flutter 3.41.9 低于 24 警告、低于 23 直接构建报错，
        // 取两侧交集为 24（PRD §6.7）。代价是放弃 Android 5.0–6.0。
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 小米推送客户端凭据（空串 = 未配置，原生侧跳过注册）。
        buildConfigField("String", "MIPUSH_APP_ID", "\"$miPushAppId\"")
        buildConfigField("String", "MIPUSH_APP_KEY", "\"$miPushAppKey\"")
    }

    signingConfigs {
        // 正式签名：凭据与 keystore 均不入库（key.properties 见 .gitignore）。
        // keystore 本体存放于仓库外，由 key.properties 的 storeFile 指向。
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // 正式签名，不再使用 debug 签名（条目 [131] 闭合 B-2）。
            signingConfig = signingConfigs.getByName("release")
            // 关闭代码混淆与资源压缩：本轮不启用 R8/ProGuard，
            // 保持与 debug 构建一致的符号表，避免「发布包与调试包行为不一致」。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// ---------------------------------------------------------------------------
// 高德 Key 兜底闸门（2026-10-28 立）。
//
// 客户端 Key 是 Dart 编译期常量，只能由 `--dart-define` 注入
// （lib/features/map/amap_init_guard.dart）。漏传**不会编译报错**，只会在真机上
// 静默退化成「示意底图」——2026-10-28 就是这样装了一个无 Key 的包。
// Flutter 会把各 define 编码后经 `-Pdart-defines` 递给 Gradle，故在此 fail-closed：
// release 缺 Key 直接构建失败；debug 缺 Key 打印显式告警。
// ---------------------------------------------------------------------------
val dartDefinesRaw: String = project.findProperty("dart-defines")?.toString().orEmpty()

/// 解码 Flutter 透传给 Gradle 的 dart-defines（每条为 base64 的 `KEY=VALUE`）。
///
/// 参数：无（读 `dart-defines` Gradle 属性）。
/// 返回：`KEY=VALUE` 映射；属性缺失或单条解码失败时跳过该条。
fun decodedDartDefines(): Map<String, String> =
    dartDefinesRaw.split(",")
        .filter { it.isNotBlank() }
        .mapNotNull { encoded ->
            runCatching {
                String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
            }.getOrNull()
        }
        .mapNotNull { entry ->
            val idx = entry.indexOf('=')
            if (idx <= 0) null else entry.substring(0, idx) to entry.substring(idx + 1)
        }
        .toMap()

/// 是否为当前模块产出 release 包的装配任务（`assembleRelease` / `bundleRelease` 等）。
///
/// 参数：[task]：待判定的 Gradle 任务。
/// 返回：true 表示该任务会产出 release 产物。
fun isReleaseArtifactTask(task: org.gradle.api.Task): Boolean =
    task.project.path == project.path &&
        (task.name.startsWith("assemble") || task.name.startsWith("bundle")) &&
        task.name.endsWith("Release")

val appProjectPath: String = project.path

gradle.taskGraph.whenReady(
    object : org.gradle.api.Action<org.gradle.api.execution.TaskExecutionGraph> {
        override fun execute(graph: org.gradle.api.execution.TaskExecutionGraph) {
            if (!decodedDartDefines()["AMAP_ANDROID_KEY"].isNullOrEmpty()) return
            val hint = "请带上 --dart-define=AMAP_ANDROID_KEY=<key> 重试" +
                "（真机调试用 tool/dev-run.ps1，出包用 deploy/scripts/release-gate.sh）。"
            if (graph.allTasks.any(::isReleaseArtifactTask)) {
                throw GradleException(
                    "AMAP_ANDROID_KEY 未注入：release 包的地图会退化为示意底图。$hint",
                )
            }
            val buildingDebugApk = graph.allTasks.any { task ->
                task.project.path == appProjectPath &&
                    task.name.startsWith("assemble") &&
                    task.name.endsWith("Debug")
            }
            if (buildingDebugApk) {
                logger.warn("[高德Key] 本次 debug 构建未注入 AMAP_ANDROID_KEY，地图将显示示意底图。$hint")
            }
        }
    },
)

flutter {
    source = "../.."
}

dependencies {
    // 小米推送 7.12.4（官方 AAR，文件依赖无 group，规避 lint 崩溃）。
    implementation(files("libs/MiPush_SDK_Client_7_12_4-C_3rd.aar"))
}
