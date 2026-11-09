plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mingtu.ai.mingtu_ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mingtu.ai.mingtu_ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // v0.6: 24, not the Flutter default 21 -- ultralytics_yolo's
        // LiteRT 2.3 runtime declares minSdk 24.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABI coverage (P0, 2026-11-09): the demo APK must run
        // on 64-bit-only phones (e.g. Xiaomi 15) -- an
        // armeabi-v7a-only package installs there but exits
        // immediately because the 32-bit engine cannot load.
        // Keep arm64-v8a FIRST and never ship v7a alone; the
        // per-ABI build command is in the root README.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // Compress the native libraries inside the APK
    // (extracted at install time): the arm64 demo APK was
    // ~30 MB mostly because of the uncompressed engine /
    // LiteRT .so files.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // P0 launch crash (Xiaomi 15 logcat, 229601e): the
            // app died in androidx.startup with "Failed to
            // create an instance of
            // androidx.work.impl.WorkDatabase" -- R8 had
            // stripped/obfuscated the Room-generated
            // WorkDatabase_Impl. Demo builds therefore ship
            // UNMINIFIED so no plugin class (Room/WorkManager,
            // LiteRT, camera, TTS/ASR) can be stripped, and the
            // keep rules in proguard-rules.pro are wired in for
            // if minify is ever re-enabled.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
