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

Published on **JitPack**; `v0.1.4` resolves today (the repository is tagged, and JitPack builds
the `android/` project from that tag):

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

// app/build.gradle.kts
implementation("com.github.KeydaAI:keyda-business-sdks:v0.1.4")
```

To build against an unreleased commit instead, publish it locally from a clone:

```bash
cd android && ./gradlew :keyda-bot:publishToMavenLocal   # in.keyda:keyda-bot:0.1.4
```

and add `mavenLocal()` to your repositories, with `implementation("in.keyda:keyda-bot:0.1.4")`.
`in.keyda:keyda-bot` on Maven Central is the intended long-term home; it is not there yet, and
this README will say so until it is.

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
* **No dependencies beyond `kotlin-stdlib`.** Not AndroidX, not appcompat, nothing else — the
  published POM declares only `org.jetbrains.kotlin:kotlin-stdlib`, which a Kotlin app already
  has and a Java app gets for free. The library is compiled with Kotlin `apiVersion` /
  `languageVersion` 1.9, so a consumer on a Kotlin 1.9+ compiler can read its metadata. The Activity extends
  `android.app.Activity` and the SDK ships no resources at all, so there is no `R` class, no
  strings to merge and no colours to collide with yours. Check it yourself with
  `./gradlew :app:dependencies`.

The SDK's manifest adds one permission to your app, `android.permission.INTERNET`. It adds no
others, no `<queries>`, no content provider and no startup initializer. The file picker below
needs none of those either: it is the system chooser (`ACTION_GET_CONTENT`), which asks for no
permission and reaches the gallery and the documents providers without one.

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
* **The chrome follows the chat's theme.** See "Theme" below: the page announces the owner's
  Theme setting through a one-method JavaScript bridge (`window.KeydaBotNative.onTheme`), and the
  Activity paints its window, status and navigation bars, spinner and retry screen to match. On
  Android 10+ the Activity switches itself to the platform DayNight theme so that a "Match the
  visitor" bot actually sees the device's dark mode inside the WebView.
* **A tap on the chat's attach button opens a picker.** The `<input type="file">` behind it
  reaches `WebChromeClient.onShowFileChooser`, which hands the page's own `accept` list and
  `multiple` attribute to the system chooser — gallery, Photos, Drive, Files, whatever the phone
  has — and returns every file the customer chose, not just the first. Cancelling is answered too:
  a file request left unanswered makes the WebView ignore the attach button for the rest of the
  conversation. There is no camera path, on purpose (see Limitations).
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

## Theme

Light, dark or "Match the visitor" is set once by the owner in the dashboard, and the hosted page
resolves it — it is the page that knows the setting. The page then reports the result to this
SDK, which colours everything it owns around the chat to match: dark background `#0b1220` with
light status-bar text, or light `#f7f8fc` with dark status-bar text; the loading spinner and the
retry screen follow, and the retry button takes the owner's accent. Until the page has reported
(and against a backend that predates this), the screen follows the device's own dark-mode
setting, which is what "Match the visitor" means. There is no theme parameter on this SDK: a
host app cannot override what the owner chose. Below Android 6.0 the status bar icons cannot be
made dark, so the light theme keeps a dark status bar there; below Android 8.0 the same holds for
the navigation bar.

## Limitations

Stated plainly, because finding these out after shipping is worse:

* **No offline.** It is a hosted page. No connection, no chat — the customer gets the retry screen.
* **No push notifications.** Nothing arrives while the chat is closed.
* **No theme API.** The owner sets the theme in the dashboard and the page carries it (see
  "Theme" above). There is no call to restyle the chat, or the screen around it, from your app.
* **No inline or embedded view.** The chat is a full-screen Activity; there is no fragment or view
  you can put inside one of your own screens.
* **Seven English strings.** The retry screen's copy, and the toast shown when nothing on the
  phone can open a link or pick a file, are compiled in, because the AAR ships no resources and
  therefore no translations. Everything the customer reads *inside* the chat comes
  from the page, in the language it is configured in.
* **No camera in the picker.** Attachments come from the gallery and the documents providers. A
  "take a photo now" path would need a FileProvider inside this AAR — which ships no content
  provider by design — and would drag your app's CAMERA permission in with it: a host that
  declares the permission without holding it makes the capture intent throw. Customers can still
  photograph something with the camera app and attach it from the gallery.
* **One chat at a time.** `show()` while the chat is open is a no-op, by design.

## Build from source

```bash
cd android
./gradlew :keyda-bot:assembleRelease      # keyda-bot/build/outputs/aar/
./gradlew :keyda-bot:publishToMavenLocal  # in.keyda:keyda-bot:0.1.4
./gradlew :keyda-bot:lintRelease          # kept at zero errors
```

Build it on a **JDK 17** (`JAVA_HOME=/opt/homebrew/opt/openjdk@17`, or Android Studio's bundled
JDK). On a JDK 25 `JAVA_HOME`, Gradle 8.13 fails with nothing but the string `25.0.2` for an error
message, which tells you nothing about what is wrong.

The one contract every Keyda SDK implements is in [CONTRACT.md](../CONTRACT.md).

## Licence

MIT — see [LICENSE](../LICENSE).
