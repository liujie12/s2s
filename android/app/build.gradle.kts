import java.util.Properties
import java.io.FileInputStream

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

flutter {
    source = "../.."
}
