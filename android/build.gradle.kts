// Versions are pinned, not ranged. The wrapper in this directory pins Gradle 8.13; AGP 8.9.1
// requires Gradle 8.11.1 or newer, and Kotlin 2.1.20 is the closest KGP release tested against
// that Gradle line. Bumping one of the three without checking the other two is how this build
// starts failing with "Inconsistent JVM-target compatibility" or a KGP/Gradle warning wall.
plugins {
    id("com.android.library") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
}
