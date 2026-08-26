# Keyda Bot for Android

`in.keyda:keyda-bot` opens `https://keyda.in/business/chat/<your client id>` in a full-screen
WebView. That is the whole library, and this page is not going to pretend otherwise.

There is exactly one Keyda chat interface, served by the platform, and every Keyda SDK loads that
same page. It is why the welcome message, the accent colour or the business hours an owner changes
in their dashboard are live inside your app the moment they save, with no release on your side.
The cost is the honest one: it is a web page in a WebView. It needs a connection, and it will
never feel more native than a web page does.

What this SDK adds on top is the part that is easy to get wrong: the keyboard not covering the
message box, links not eating the conversation, and a failed load showing a retry instead of
taking your app down with it.

## Install

The Gradle project lives in the `android/` directory of this repository.

**JitPack** (once this repo is tagged, and JitPack is pointed at `android/`):

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

// app/build.gradle.kts
implementation("com.github.KeydaAI:keyda-business-sdks:v0.1.2")
```

Replace `keyda` with the GitHub account this repository sits under. If no tag exists yet, that
coordinate does not resolve — nothing is on JitPack or Maven Central at the time of writing, so
until the first tag, publish it locally from a clone:

```bash
cd android && ./gradlew :keyda-bot:publishToMavenLocal   # in.keyda:keyda-bot:0.1.2
```

and add `mavenLocal()` to your repositories. `in.keyda:keyda-bot` on Maven Central is the intended
home; it is not there yet, and this README will say so until it is.

## Use

```kotlin
import `in`.keyda.bot.KeydaBot                       // backticks required, see below

KeydaBot.init(this, "kb_live_9f4c2a10")              // once, in Application.onCreate()
supportButton.setOnClickListener { KeydaBot.show(this) }
```

From Java, every call is static:

```java
KeydaBot.init(this, "kb_live_9f4c2a10");
supportButton.setOnClickListener(v -> KeydaBot.show(this));
```

Get the client id from **Install** in the [Keyda Business dashboard](https://keyda.in/business/app/).

### `in` is a Kotlin keyword

The package is `in.keyda.bot`, and `in` is reserved in Kotlin, so Kotlin files must escape it in
the import: <code>import `in`.keyda.bot.KeydaBot</code>. Java is unaffected. Android Studio
writes the backticks for you when it auto-imports.

## The whole API

| Call | Does |
|---|---|
| `KeydaBot.init(context, clientId, baseUrl = "https://keyda.in/business")` | stores and validates the configuration |
| `KeydaBot.show(activity)` | opens the chat over your app |
| `KeydaBot.dismiss()` | closes it; safe when it is not open, safe from any thread |
| `KeydaBot.isShowing` | whether the chat is on screen right now |

There is no message API, no unread count and no identify call, because there is nothing behind
them yet. A method that does not work end to end is worse than a missing one.

### Overriding the base URL

Self-hosting or staging:

```kotlin
KeydaBot.init(this, "kb_live_9f4c2a10", "https://chat.mystore.in")
```

Trailing slashes are trimmed. `http://` is accepted so a local server works; anything else is
rejected.

### Two calls throw, on purpose

Both are integration mistakes, identical on every device and every launch, so they surface at your
desk rather than in front of a customer:

* `init()` throws `IllegalArgumentException` if the client id is not `kb_live_` + 8–48 hex
  characters, or if the base URL has no `http(s)` scheme and host.
* `show()` throws `IllegalStateException` if `init()` has not run.

Everything else — no network, no WebView on the device, a 404, a bad certificate, the WebView's
render process being killed — is handled on screen with a **Try again** button. The SDK does not
throw at your users.

## Requirements

* **minSdk 21** (Android 5.0), **compileSdk 34**
* **JVM target 17** for Java and Kotlin (AGP 8 itself requires JDK 17)
* Built with AGP 8.9.1, Kotlin 2.1.20, Gradle 8.13 (the wrapper in this directory)
* Kotlin is not required in your app
* **Zero dependencies.** Not AndroidX, not appcompat, nothing. The Activity extends
  `android.app.Activity` and the SDK ships no resources at all, so there is no `R` class, no
  strings to merge and no colours to collide with yours. Check it yourself with
  `./gradlew :app:dependencies`.

The SDK's manifest adds one permission to your app, `android.permission.INTERNET`. It adds no
others, no `<queries>`, no content provider and no startup initializer.

## What it does inside, briefly

* **JavaScript and DOM storage are on.** DOM storage is what keeps a visitor's conversation
  attached to them across an app restart.
* **Links leave the chat.** Any navigation away from the chat page — the "Powered by Keyda" link
  included — opens in the system browser via `ACTION_VIEW`. It never replaces the conversation
  with a page that has no way back. That link lives on the *same host* as the chat, so the check
  is the page's path and not just its origin; an origin-only check would keep it in the WebView.
  `tel:`, `mailto:` and `upi:` links hand off to the phone, mail and payment apps, and a link
  nothing on the device can open shows a toast rather than doing nothing. Two things stay inside:
  an `<iframe>` in the page, which is part of the conversation rather than a replacement for it,
  and a redirect your own host performs while the chat is still loading (apex to `www`, `http` to
  `https`, a staging alias), so a redirecting base URL does not end up opening the chat in
  Chrome.
* **The keyboard does not cover the input.** The Activity is `adjustResize`, and on Android 15+
  where the system forces apps edge-to-edge and ignores that, it pads for the IME insets itself.
* **Safe areas are respected** — status bar, gesture bar and display cutout.
* **Back** goes back through the chat's own history first, then closes. Predictive back (API 33+)
  is registered as well as the classic callback.
* **A slow connection shows a spinner, then a retry.** On 2G and patchy 3G the page can take
  several seconds; a blank white screen for those seconds reads as a broken app.
* **If Android kills the WebView's render process**, the chat view is rebuilt and the customer is
  offered a retry. The default behaviour would take your whole app down with it.
* **No analytics, no device identifiers, no cookies of ours.** The only thing added to the
  User-Agent is `KeydaBot/<version> (Android)`, which carries a version and nothing else.
* **R8**: nothing needs to be added to your `proguard-rules.pro`. The AAR ships
  `consumer-rules.pro`, which explains what is kept and why.

## Limitations

Stated plainly, because finding these out after shipping is worse:

* **No offline.** It is a hosted page. No connection, no chat — the customer gets the retry screen.
* **No push notifications.** Nothing arrives while the chat is closed.
* **No native theming.** The accent the dashboard controls is the extent of it. There is no API to
  restyle the chat from your app.
* **No inline or embedded view.** The chat is a full-screen Activity; there is no fragment or view
  you can put inside one of your own screens.
* **Six English strings.** The retry screen's copy is compiled in, because the AAR ships no
  resources and therefore no translations. Everything the customer reads *inside* the chat comes
  from the page, in the language it is configured in.
* **No file picker.** The SDK implements no `onShowFileChooser`, so if the hosted chat ever offers
  an attach button, it will not open a picker.
* **One chat at a time.** `show()` while the chat is open is a no-op, by design.

## Build from source

```bash
cd android
./gradlew :keyda-bot:assembleRelease      # keyda-bot/build/outputs/aar/
./gradlew :keyda-bot:publishToMavenLocal  # in.keyda:keyda-bot:0.1.2
./gradlew :keyda-bot:lintRelease          # kept at zero errors
```

Build it on a **JDK 17** (`JAVA_HOME=/opt/homebrew/opt/openjdk@17`, or Android Studio's bundled
JDK). On a JDK 25 `JAVA_HOME`, Gradle 8.13 fails with nothing but the string `25.0.2` for an error
message, which tells you nothing about what is wrong.

The one contract every Keyda SDK implements is in [CONTRACT.md](../CONTRACT.md).

## Licence

MIT — see [LICENSE](../LICENSE).
