import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

// One source of truth for the version. It is both the published Maven version and the string the
// WebView appends to its User-Agent; when those two drift, a support ticket says the app runs a
// version that was never released.
val sdkVersion = "0.1.1"

android {
    namespace = "in.keyda.bot"
    compileSdk = 34

    defaultConfig {
        minSdk = 21

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
        // compatibility detected". AGP 8 itself requires JDK 17 to run.
        jvmTarget.set(JvmTarget.JVM_17)
    }
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
