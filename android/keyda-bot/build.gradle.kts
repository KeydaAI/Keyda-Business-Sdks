import org.jetbrains.kotlin.gradle.dsl.JvmDefaultMode
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    // No org.jetbrains.kotlin.android: AGP 9 compiles the Kotlin sources itself.
    id("com.android.library")
    id("maven-publish")
}

// One source of truth for the version. It is both the published Maven version and the string the
// WebView appends to its User-Agent; when those two drift, a support ticket says the app runs a
// version that was never released.
val sdkVersion = "0.2.0"

android {
    namespace = "in.keyda.bot"
    // 36 (Android 16) for the APIs a host app targeting 36 runs this Activity under - edge-to-edge
    // and predictive back.
    compileSdk = 36

    defaultConfig {
        minSdk = 21

        // Not a floor for the host app. AGP 9 writes compileSdk into the AAR as minCompileSdk by
        // default, which would refuse to build every app still compiling against 34 or 35 - for
        // API names that only this library's own code is compiled against. 0.1.4 said 1.
        aarMetadata {
            minCompileSdk = 1
        }

        // See consumer-rules.pro. It is shipped inside the AAR so a consumer's R8 run picks it up
        // without them having to paste anything into their own proguard file.
        consumerProguardFiles("consumer-rules.pro")

        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }

    buildFeatures {
        // The only generated class we want. This module ships no resources at all -- no colours to
        // clash with the host app's, no strings to merge -- so nothing else needs generating.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            // A library must not be shrunk here: R8 in the *consuming* app is the only place that
            // knows what is actually reachable. Shrinking twice strips code the app still calls.
            isMinifyEnabled = false
        }
    }

    lint {
        // A library that ships lint errors makes every consumer's build noisier, so this stays at
        // zero. UseRequiresApi is the one check that cannot be satisfied: it asks for
        // @RequiresApi, which lives in androidx.annotation, and CONTRACT rule 5 says this SDK
        // takes no dependencies. The platform's own @TargetApi is used instead, on overrides that
        // Android itself never calls below the version named.
        disable += "UseRequiresApi"
        abortOnError = true
    }

    publishing {
        singleVariant("release") {
            // Sources ride along so an integrator can step into the WebView setup and see exactly
            // what the SDK does inside their app. There is nothing here we would hide.
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        // Must match compileOptions above, or the build stops with "Inconsistent JVM-target
        // compatibility detected". AGP 9 itself requires JDK 17 to run.
        jvmTarget.set(JvmTarget.JVM_17)
        // Pinned below the 2.4.21 compiler that builds this AAR on purpose. The Kotlin metadata
        // written into the AAR carries the LANGUAGE version, not the compiler version, and a
        // consumer's compiler refuses metadata more than one version newer than itself ("Module
        // was compiled with an incompatible version of Kotlin"). 2.0 is the oldest the 2.4
        // compiler still writes, and a 1.9 compiler can still read it. Java consumers never see
        // any of this; the pin costs nothing on the library side, which uses no newer language
        // feature.
        apiVersion.set(KotlinVersion.KOTLIN_2_0)
        languageVersion.set(KotlinVersion.KOTLIN_2_0)
        // KeydaBot.Listener's empty methods become real Java default methods, so a Java app
        // implements only the one it needs - as the KDoc says. Without it Java sees them abstract.
        jvmDefault.set(JvmDefaultMode.ENABLE)
    }
    // The kotlin-stdlib the AAR's POM asks for, which Gradle then resolves into every host app.
    // By default it is the compiler's own version, so moving the build to a new compiler would
    // silently push a newer stdlib - one an older Kotlin compiler in the host cannot read - into
    // apps that changed nothing. Held at what 0.1.2-0.1.4 shipped with; the apiVersion pin above
    // keeps the code inside what this stdlib has.
    coreLibrariesVersion = "2.1.20"
}

dependencies {
    // Intentionally empty. CONTRACT rule 5: an SDK a small business drops into their app must not
    // add trackers, or a second copy of a support library, to it. Everything used here
    // (WebView, Activity, WindowInsets) is in the platform.
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "in.keyda"
            artifactId = "keyda-bot"
            version = sdkVersion

            afterEvaluate { from(components["release"]) }

            pom {
                name.set("Keyda Bot")
                description.set("Opens a Keyda Business chat page in a full-screen WebView.")
                url.set("https://keyda.in/business")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
            }
        }
    }
}
