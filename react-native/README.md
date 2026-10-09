# @keyda/bot-react-native

This package opens your Keyda bot's **hosted chat page** — `https://keyda.in/business/chat/<clientId>` — inside a React Native `Modal` and `WebView`. It is a wrapper. There is no native chat UI in here, and there is not going to be one.

That is the deliberate trade. One chat renderer exists (the web widget the platform serves), so when you change your bot's welcome message, accent colour or knowledge in the dashboard, it is live in your app the next time someone opens the chat — no app release, no store review. What you give up is real, and it is listed under [Limitations](#limitations). Read that section before you ship.

## Install

```sh
npm install @keyda/bot-react-native react-native-webview
cd ios && pod install
```

`react-native-webview` is a **peer dependency — your app installs it, this package does not bundle it.** React Native has no built-in WebView, and vendoring a second copy would fight with the one your app very likely already has. That peer is the only dependency of any kind: no analytics SDK, no device identifiers, nothing that phones home.

The peer floor is **`react-native-webview` 13.3.0**, the first release with `onOpenWindow`. This SDK relies on it: on iOS a `target="_blank"` link (which "Powered by Keyda" is) is delivered through `onOpenWindow` before `onShouldStartLoadWithRequest` ever runs. On 13.0–13.2 the prop does not exist, the link falls back to loading inside the WebView, and the navigation handler catches it — it still opens in the browser, but by a route this package does not test.

Tested with React Native 0.87 on the New Architecture, and in Expo (SDK 57): in Expo Go — nothing
native to add, `react-native-webview` is part of Expo Go — and in a development build
(`npx expo run:ios` / `run:android`). `npx expo install react-native-webview` picks the WebView
version that matches your Expo SDK; 13.x and 14.x both work.

## Usage

```tsx
import React from 'react';
import {Button, View} from 'react-native';
import {KeydaBot, useKeydaBot} from '@keyda/bot-react-native';

export default function SupportScreen() {
  const bot = useKeydaBot('kb_live_2f9c81ba77d04e6a');

  return (
    <View>
      <Button title="Chat with us" onPress={bot.show} />
      <KeydaBot {...bot.botProps} />
    </View>
  );
}
```

`useKeydaBot` only holds the open/closed state. If you already keep that state yourself — in Redux, in a navigator, anywhere — skip the hook and render the component directly:

```tsx
<KeydaBot
  clientId="kb_live_2f9c81ba77d04e6a"
  visible={open}
  onClose={() => setOpen(false)}
/>
```

## API

That is the whole surface. There is no message API and no user-identity call. The one unread signal, `useKeydaBotReplies`, is a reply from a person at the business that the chat has not shown yet — which the server can answer honestly. See [Limitations](#limitations).

### `<KeydaBot />`

| Prop | Type | |
|---|---|---|
| `clientId` | `string` | Required. From **Install** in the [dashboard](https://keyda.in/business/app/). |
| `baseUrl` | `string?` | Defaults to `https://keyda.in/business`. |
| `visible` | `boolean` | Required. Presents the chat over your app. |
| `onClose` | `() => void` | Required. Fired by the ✕, and by Android's back when the chat has no sheet open (see below). |
| `question` | `string?` | Put in the chat's message box, unsent, when it opens; a new value while it is open replaces the text. It travels in the URL's #fragment, never in a server log. Up to 500 characters, as one line: the chat joins lines and collapses runs of spaces. |
| `visitor` | `{name?, phone?, email?}?` | Your signed-in customer, offered in the chat's forms — see [Your signed-in customer](#your-signed-in-customer). |

### `useKeydaBot(clientId, baseUrl?)`

Returns `{ isShowing, show(question?), dismiss(), botProps }`. Spread `botProps` onto `<KeydaBot />`. `bot.show('Is this in stock?')` opens the chat with that question in its message box; called again with the same text, it puts it back even if the customer edited it.

### `<KeydaBotChat />` — the chat inside one of your own screens

For a Help tab or a support screen, instead of the full-screen modal:

```tsx
<KeydaBotChat clientId="kb_live_2f9c81ba77d04e6a" question="Is this in stock?" style={{flex: 1}} />
```

| Prop | Type | |
|---|---|---|
| `clientId`, `baseUrl`, `question`, `visitor` | | As on `<KeydaBot />`. |
| `focused` | `boolean?` | Is this screen the one in front? Default `true`. In a tab or under other screens that stay mounted, pass React Navigation's `useIsFocused()` (or your tab's selected state). |
| `style` | `ViewStyle?` | Size and place it like any view. |
| `onCanGoBackChange` | `(open: boolean) => void` | Called when the chat opens a sheet over the conversation (an item, the cart, a booking) and when the last one closes. |

No close button (your screen's navigation is the way out), and no insets but the keyboard's: lay it out clear of the status and navigation bars as you would any view. On Android, back closes a sheet the chat has open before your app's own back handling sees it, and is your app's back otherwise. `BackHandler` is global, so a chat that is mounted but not in front must be told (`focused={false}`): it then leaves back to your app — it would otherwise close a sheet in a chat nobody can see — and counts as off screen for `useKeydaBotReplies`.

### `useKeydaBotReplies(clientId, options?)`

A reply from the business that came while no chat was on screen. Returns `{ hasUnreadReply, checkForReplies() }`.

```tsx
import AsyncStorage from '@react-native-async-storage/async-storage';

const replies = useKeydaBotReplies(CLIENT_ID, {
  storage: AsyncStorage,                 // optional: keep watching across app restarts
  onReply: () => console.log('new reply'),
});
<Badge visible={replies.hasUnreadReply} />
```

A customer who asks for a person leaves their details and closes the chat; you answer from the dashboard later. The chat shows the answer the next time it opens; this tells your app it is there. The SDK asks when your app comes to the foreground — once a minute at most, and only for chats in which the customer asked for a person in the last 14 days. `checkForReplies()` asks now (once in 10 seconds at most). `hasUnreadReply` stays true until the customer opens the chat (`<KeydaBot visible>`, or a focused `<KeydaBotChat />`), which shows the reply; `onReply` is called once per new reply. A `<KeydaBotChat focused={false}>` still draws a reply in its hidden tab, and that does not count as seen: the dot stays on, and `onReply` is called, until the tab is selected.

| Option | Type | |
|---|---|---|
| `baseUrl` | `string?` | The same as on `<KeydaBot />`. |
| `storage` | `{getItem, setItem, removeItem?}?` | Where to remember the chats to ask about: AsyncStorage, or a wrapper round MMKV. This package adds no dependency, so without one they are watched only while the app runs. Chat ids and times only — what the WebView keeps already. |
| `onReply` | `() => void` | Once per new reply, while no chat is on screen. |

There is no push: a reply is noticed when the app is opened.

## Your signed-in customer

```tsx
<KeydaBot {...bot.botProps} visitor={user ? {name: user.name, phone: user.phone, email: user.email} : undefined} />
```

The chat then does not ask what your app already knows. The details are **offered, never sent**: they appear in "talk to a person", an order, a booking, and a welcome question for a name, a phone number or an email, and the customer submits them. Until then nothing leaves the phone — they travel in the URL's #fragment, and a change reaches a chat already open. They are your app's word, not a verified identity. A value that does not look like what it claims is dropped whole, never cut: a name of 1–80 characters on one line, a phone number with 8–15 digits (and only spaces and `+ - ( ) .` besides), an email address up to 254 characters. Pass `undefined` when the customer signs out.

### `buildChatUrl(clientId, baseUrl?)`

The URL the WebView loads: `{baseUrl}/chat/{clientId}`. Useful if you would rather open the chat in the system browser, or share it as a link.

### `isValidClientId(clientId)`

`true` for `kb_live_` followed by 8–48 hex characters.

## Your client id

Copy it from **Install** in the Keyda Business dashboard. It looks like `kb_live_2f9c81ba77d04e6a`, and it is the same id your website widget uses.

An id of any other shape **throws** as soon as the component or the hook renders:

```
[KeydaBot] Invalid clientId "kb_live_YOUR_ID_HERE". Expected kb_live_ followed by
8-48 hex characters — copy it from Install in the Keyda Business dashboard.
```

That is on purpose, and it is the one place this SDK raises. A wrong id can only be a mistake in your integration, and it is deterministic — you hit it the first time you run the screen. The alternative is silence at build time and a "This chat link is not valid" page in front of a paying customer. Runtime failures — no network, a dead server — never throw; see below.

## Self-hosting and staging

```tsx
<KeydaBot clientId="kb_live_…" baseUrl="https://chat.mycompany.in" visible={open} onClose={close} />
```

`baseUrl` must be an absolute `http(s)` origin. A **path prefix is kept**, so a self-host mounted under one works — `https://acme.example/support` loads `https://acme.example/support/chat/{clientId}`. A query string or a `#fragment` **throws**, because the SDK appends `/chat/{clientId}` and `https://host?x=1` would otherwise build the unusable `https://host?x=1/chat/kb_live_…`.

Point it at a host that redirects somewhere else and the redirect is treated as a link off the chat page (see below), which means it opens in the browser instead of loading.

## The keyboard, and safe areas

Nothing to configure on either platform, and in particular **`android:windowSoftInputMode` on your activity is not what governs this.** The chat is presented in a React Native `Modal`, which on Android is a `Dialog` with its own window, and React Native sets `SOFT_INPUT_ADJUST_RESIZE` on that window itself — your manifest setting does not reach it either way. On iOS the SDK resizes the WebView with a `KeyboardAvoidingView`, which shrinks the page's viewport and lifts the message box clear of the keys.

Safe areas: on iOS the chat is wrapped in React Native's core `SafeAreaView`, so it never draws under a notch or the home indicator. On Android, an app that targets Android 15 or later is edge-to-edge (every app Google Play accepts now targets 16, and React Native 0.81+ draws its `Modal` under both system bars), so this package keeps the close button below the status bar, "Powered by Keyda" above the navigation bar and the message box above the keyboard itself — measured, so an app that is not edge-to-edge keeps the window's own insets and nothing is counted twice. It reads the navigation bar's height from `react-native-safe-area-context` when your app has it (React Navigation and Expo apps do) and otherwise learns it the first time the keyboard opens; no dependency is added.

When the chat closes, an Android app that never set a status-bar style of its own gets its own look back (dark icons on a light app): React Native's default would otherwise have left the time and battery white on white.

## Back, on Android

The chat opens sheets over the conversation — an item over the menu, the cart, a booking. Android's back closes the sheet on top first, and calls `onClose` only when none is open. The page answers through `KeydaBot.back()`; a page too old to have it, or one that does not answer within half a second, gets `onClose` straight away.

## Links open outside the chat

The chat page carries a real "Powered by Keyda" link. Every navigation that is not the bot's own chat URL — including that one, which happens to sit on the same origin — is handed to `Linking.openURL` and opens in the system browser. The WebView itself never leaves the chat, so a stray tap cannot replace a customer's conversation with a web page they have no way back from.

What gets handed to the OS is an allowlist, not everything the page might emit: `http`, `https`, `mailto`, `tel`, `sms`, `whatsapp`, `upi`, `geo`, `maps`. Anything else — an `intent://`, a `javascript:`, a private scheme — is blocked and nothing happens. On Android an `intent://` URL names an arbitrary component to launch, and a chat answer is not a source this SDK is willing to launch components from.

## When it fails

Never with an exception. A failed load, an HTTP error on the chat document, or an Android renderer killed under memory pressure all end at the same place: a "Chat didn’t load" screen with a **Try again** button that mounts a fresh WebView. The conversation is not lost — the page keeps its conversation id in DOM storage, which is why the SDK enables DOM storage and never runs the WebView in incognito mode.

## Theme

Set the theme in the Keyda Business dashboard — Match the visitor, Always light or Always dark — and the accent alongside it. The hosted page resolves that setting and announces it to this container as it loads, so the status-bar text, the close button, the loading cover and the retry screen match the chat rather than contradicting it; a Match-the-visitor bot re-announces when the OS scheme flips while the chat is open. Until the page has reported (the first frames of a load, or a self-hosted backend that predates the announcement) the container follows the device scheme, which is what Match the visitor means anyway. There is no theme prop on `<KeydaBot />` and there is not going to be one: the theme is the owner's, and it is set in one place.

## Attachments

If the bot's chat offers an attach button, the picker opens on both platforms with no code and no prop here: `react-native-webview` implements Android's `onShowFileChooser` itself, and WebKit presents its own picker on iOS. What is not automatic is the host app's side of it, and this package cannot add either of these for you.

**iOS — one `Info.plist` key, or your app is killed.** WebKit's upload action sheet offers **Take Photo or Video** for any input that accepts images. The page neither asks for the camera nor can suppress the option, and iOS terminates an app that reaches the camera with no usage description — in front of the customer, mid-conversation. Add:

```xml
<key>NSCameraUsageDescription</key>
<string>Attach a photo to your support conversation.</string>
```

Add `NSMicrophoneUsageDescription` too if the chat accepts video. The photo library goes through `PHPicker` and needs no key of its own.

**Android — nothing, unless the page asks to capture.** Choosing from the gallery or a documents provider needs no permission on any supported version. Only an input written with `capture` reaches the camera app directly, and on Android 11+ that needs your manifest to say it can see one:

```xml
<queries>
  <intent><action android:name="android.media.action.IMAGE_CAPTURE" /></intent>
</queries>
```

One trap worth knowing: if your app *declares* `CAMERA` in its manifest but has not been granted it, Android refuses the capture intent rather than prompting. Either request the permission before the customer opens the chat, or do not declare it.

Nothing in this package reads the files. They go straight from the picker to the hosted page's own upload, exactly as they would in a browser.

## Inside the chat

All of this is the hosted page's, so it reaches your app without an SDK update:

* **A welcome message with suggestion buttons**, in the language the bot is set to; the header
  says "AI assistant".
* **The conversation is kept on the device for 24 hours**, and the chat makes no visitor id.
  (On a website a conversation lasts one browser tab.)
* **Orders and bookings**, when the business takes them: a cart, booking dates and times, a
  link to call the business when an order or booking has waited too long, and "Add to
  calendar" for a confirmed booking.
* **Attachments**: photos (JPEG, PNG, WebP, GIF) and PDF, DOCX, TXT, CSV and MD files.
* **Links leave the chat**: `tel:` opens the dialer, `mailto:` the mail app, and web links the
  browser.
* **"Add to calendar" is a link to an `.ics` file.** iOS opens it in Calendar as a calendar to
  subscribe to, so the booking arrives as a small calendar of its own rather than as one event
  in yours. Android offers the phone's calendar app when that app imports `.ics` files — current
  Google Calendar does — and otherwise the browser downloads the file.

## Limitations

Stated plainly, because finding these out after shipping is worse.

- **No offline.** It is a hosted page. No network, no chat — you get the retry screen.
- **No push notifications.** A reply that arrives while your app is closed is noticed when the app is next opened (`useKeydaBotReplies`), not before.
- **No message or identity API.** You cannot send a message programmatically or read the transcript, and `visitor` offers details to the customer — it does not tell the server who they are. Those are absent rather than half-built.
- **Closing unmounts the WebView.** React Native's `Modal` tears its children down when it hides, so reopening reloads the page. The visitor's conversation resumes from DOM storage; the reload itself is a real cost on a slow connection.
- **No theme prop.** The owner picks the theme once in the dashboard (Match the visitor / Always light / Always dark); the hosted page resolves it and tells this container, which follows. See [Theme](#theme). An app cannot override that choice.
- **Core `SafeAreaView`, which React Native has deprecated, on iOS.** In an iOS development build React Native shows a one-time "SafeAreaView has been deprecated" warning attributed to this package, as a toast over the bottom of the screen — dismiss it; release builds show nothing. (Android does not read it: there it pads nothing.) It is the only dependency-free source of the iOS notch and home-indicator insets, and this package adds no dependency to replace it; it will move to `react-native-safe-area-context` (as an optional peer) before React Native removes the core view. Until then the `react-native` peer has no upper bound, so the removal release would break the modal layout — pin your `react-native` upgrade to a version of this package that says it is supported.
- **Attachments are your app's permissions, not this package's.** The chat page's own attach button opens the picker through `react-native-webview` on Android and WebKit on iOS, so nothing here has to change — but an iOS app without `NSCameraUsageDescription` is *terminated* when a customer picks "Take Photo or Video" from that sheet. See [Attachments](#attachments). This package still declares no permission of its own, requests none at runtime, and never reads a chosen file.
- **Ships TypeScript source, no build step.** Metro compiles it along with your app, which is the normal pattern for a React Native library. If you run Jest, add the package to `transformIgnorePatterns`:
  ```js
  transformIgnorePatterns: ['node_modules/(?!(react-native|@keyda/bot-react-native)/)'],
  ```

## Privacy

The SDK itself collects nothing. It loads the chat page; the chat page talks to Keyda's API to answer questions, and stores a conversation id in the WebView's DOM storage so a visitor's thread survives closing the app. If you use `useKeydaBotReplies`, the SDK itself also asks your `baseUrl`'s server for new rows in the chats the page is waiting on (`/api/business/v1/widget/{clientId}/messages`, with the conversation id and a time — no cookie, no identifier), and writes that list — chat ids and times — to the `storage` you pass. `visitor` stays on the phone until the customer submits a form. No device identifier is read, generated or transmitted by this package.

## Licence

MIT — see [LICENSE](LICENSE).
