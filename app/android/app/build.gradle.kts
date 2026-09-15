import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.einz"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "cc.tic.einz"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 签名配置：读取 android/key.properties（不存在则退回 debug 签名，保证 flutter run --release 可用）
            //
            // 口令可不进工作区（2026-09-15 评审 C3：本目录会被 Seafile 同步到多台机器）：
            // ① properties 路径可换：设 EINZ_ANDROID_KEY_PROPERTIES 指到同步盘之外，
            //    例如 ~/.einz/android/key.properties（keystore 也放同目录）。
            // ② 口令优先从环境变量取（可现取现用，不落盘）：
            //      security add-generic-password -a "$USER" -s einz-android-store -w '…'   # 一次性
            //      export EINZ_STORE_PASSWORD=$(security find-generic-password -a "$USER" -s einz-android-store -w)
            //      export EINZ_KEY_PASSWORD=$(security find-generic-password -a "$USER" -s einz-android-key -w)
            //    未设置环境变量时，才回落到 properties 文件里的明文值（现状，向后兼容）。
            //    注意 Gradle daemon 可能复用旧环境：若明明 export 了却取不到，
            //    先 `cd app/android && ./gradlew --stop`（或加 --no-daemon）再构建。
            val keystorePropertiesFile = rootProject.file(
                System.getenv("EINZ_ANDROID_KEY_PROPERTIES") ?: "key.properties"
            )
            val keystoreProperties = Properties().apply {
                if (keystorePropertiesFile.exists()) {
                    keystorePropertiesFile.inputStream().use { load(it) }
                }
            }
            val hasSigning = keystorePropertiesFile.exists() &&
                keystoreProperties.getProperty("storeFile") != null
            if (hasSigning) {
                signingConfig = signingConfigs.create("release") {
                    keyAlias = keystoreProperties.getProperty("keyAlias")
                    keyPassword = System.getenv("EINZ_KEY_PASSWORD")
                        ?: keystoreProperties.getProperty("keyPassword")
                    // storeFile 相对 properties 文件所在目录解析（默认与 key.properties 同目录）
                    storeFile = keystorePropertiesFile.parentFile
                        .resolve(keystoreProperties.getProperty("storeFile"))
                    storePassword = System.getenv("EINZ_STORE_PASSWORD")
                        ?: keystoreProperties.getProperty("storePassword")
                }
            } else {
                // TODO: 配置 app/android/key.properties + release keystore 后替换
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
