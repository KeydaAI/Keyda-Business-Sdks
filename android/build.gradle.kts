// Versions are pinned, not ranged. The wrapper in this directory pins Gradle 9.8.1, which AGP 9.4
// requires (9.x); AGP 9 compiles Kotlin itself ("built-in Kotlin"), so there is no Kotlin Android
// plugin to apply - the Kotlin Gradle plugin is listed here only to choose the compiler AGP uses
// (2.4.21) rather than the older one AGP depends on. Bumping one of the three without checking the
// other two is how this build starts failing with a version-compatibility wall.
plugins {
    id("com.android.library") version "9.4.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
}
