plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.livelens.livelens"
    compileSdk = flutter.compileSdkVersion
    // Pinned: local 26.3.11579264 install is corrupt (missing
    // source.properties). 27.0.12077973 is present and healthy.
    // Revisit when sherpa-onnx pins its own NDK requirement (Epic 3+).
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.livelens.livelens"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Playback capture requires API 29 (AudioPlaybackCaptureConfiguration).
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // The Flutter Gradle plugin turns on R8 minification for release
            // builds with only the default rules — which renamed our vendored
            // sherpa-onnx config classes (e.g. OfflineModelConfig -> B.k with
            // fields a,b,c...). libsherpa-onnx-jni.so reads those fields via
            // JNI GetFieldID by NAME, so every model load failed with
            // "Failed to get field ID for decodingMethod" and the VAD path
            // died on a null field ID. Wire in proguard-rules.pro, which
            // keeps com.k2fsa.sherpa.onnx.** intact.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pure-Kotlin unit tests for core/ algorithms (Epic 3 golden tests).
    testImplementation("junit:junit:4.13.2")
}
