allprojects {
    repositories {
        // Mirror-first ordering (see settings.gradle.kts rationale).
        // Flutter engine artifacts (io.flutter) live on download.flutter.io.
        // storage.googleapis.com returns 403 from this network — the official
        // CN mirror hosts the same path and is verified working (2026-08).
        maven("https://storage.flutter-io.cn/download.flutter.io")
        maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        maven("https://repo.huaweicloud.com/repository/maven/")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
