plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
