// Standalone Gradle build for the Android SDK. It deliberately does NOT include the rest of the
// monorepo: an integrator who clones this repo to look at the library should be able to open
// `android/` in Android Studio and have it resolve, without a Flutter or Node toolchain present.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Fail if any module declares its own repositories. This library ships zero dependencies
    // (CONTRACT rule 5) and a stray repository block is the usual way one sneaks in unnoticed.
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "keyda-bot-android"

include(":keyda-bot")
