pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Mirrors first: required on networks where Google/Maven Central are
        // unreachable (same reason Flutter is configured with .cn mirrors).
        // Tencent's nexus aggregates google/central/gradle-plugin artifacts.
        // Flutter engine artifacts come from the official CN mirror (the
        // googleapis origin 403s from this network — verified 2026-08).
        // Keep originals as fallbacks for unrestricted CI environments.
        maven("https://storage.flutter-io.cn/download.flutter.io")
        maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        maven("https://repo.huaweicloud.com/repository/maven/")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
