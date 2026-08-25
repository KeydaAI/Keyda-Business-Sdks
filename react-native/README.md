# @keyda/bot-react-native

This package opens your Keyda bot's **hosted chat page** — `https://keyda.in/business/chat/<clientId>` — inside a React Native `Modal` and `WebView`. It is a wrapper. There is no native chat UI in here, and there is not going to be one.

That is the deliberate trade. One chat renderer exists (the web widget the platform serves), so when you change your bot's welcome message, accent colour or knowledge in the dashboard, it is live in your app the next time someone opens the chat — no app release, no store review. What you give up is real, and it is listed under [Limitations](#limitations). Read that section before you ship.

## Install

```sh
npm install @keyda/bot-react-native react-native-webview
cd ios && pod install
```

`react-native-webview` is a **peer dependency — your app installs it, this package does not bundle it.** React Native has no built-in WebView, and vendoring a second copy would fight with the one your app very likely already has. That peer is the only dependency of any kind: no analytics SDK, no device identifiers, nothing that phones home.

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

That is the whole surface. There is no message API, no unread count and no user-identity call, because none of those work end to end today — see [Limitations](#limitations).

### `<KeydaBot />`

| Prop | Type | |
|---|---|---|
| `clientId` | `string` | Required. From **Install** in the [dashboard](https://keyda.in/business/app/). |
| `baseUrl` | `string?` | Defaults to `https://keyda.in/business`. |
| `visible` | `boolean` | Required. Presents the chat over your app. |
| `onClose` | `() => void` | Required. Fired by the ✕ and by Android's back button. |

### `useKeydaBot(clientId, baseUrl?)`

Returns `{ isShowing, show(), dismiss(), botProps }`. Spread `botProps` onto `<KeydaBot />`.

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

Safe areas: on iOS the chat is wrapped in a `SafeAreaView`, so it never draws under a notch or the home indicator. On Android the same is true, but it comes from the modal's dialog window being laid out inside the system bars rather than from anything in this package — React Native's `SafeAreaView` is a plain `View` on Android. If your app puts the modal edge-to-edge under the status or navigation bar, that inset is yours to add; this package takes no safe-area dependency to do it for you (see [Limitations](#limitations)).

## Links open outside the chat

The chat page carries a real "Powered by Keyda" link. Every navigation that is not the bot's own chat URL — including that one, which happens to sit on the same origin — is handed to `Linking.openURL` and opens in the system browser. The WebView itself never leaves the chat, so a stray tap cannot replace a customer's conversation with a web page they have no way back from.

What gets handed to the OS is an allowlist, not everything the page might emit: `http`, `https`, `mailto`, `tel`, `sms`, `whatsapp`, `upi`, `geo`, `maps`. Anything else — an `intent://`, a `javascript:`, a private scheme — is blocked and nothing happens. On Android an `intent://` URL names an arbitrary component to launch, and a chat answer is not a source this SDK is willing to launch components from.

## When it fails

Never with an exception. A failed load, an HTTP error on the chat document, or an Android renderer killed under memory pressure all end at the same place: a "Chat didn’t load" screen with a **Try again** button that mounts a fresh WebView. The conversation is not lost — the page keeps its conversation id in DOM storage, which is why the SDK enables DOM storage and never runs the WebView in incognito mode.

## Limitations

Stated plainly, because finding these out after shipping is worse.

- **No offline.** It is a hosted page. No network, no chat — you get the retry screen.
- **No push notifications.** A reply that arrives while your app is closed is not delivered anywhere. There is nothing in this package that listens for one.
- **No message, unread-count or identity API.** You cannot send a message programmatically, read the transcript, badge an unread count, or tell the bot who the logged-in user is. Those are absent rather than half-built.
- **Closing unmounts the WebView.** React Native's `Modal` tears its children down when it hides, so reopening reloads the page. The visitor's conversation resumes from DOM storage; the reload itself is a real cost on a slow connection.
- **Light only.** The chat follows the accent colour from your dashboard. There is no dark mode and no other native theming, so the container matches the page rather than your app.
- **Text only.** The chat page sends and receives text. No attachments, no images, no voice — so this SDK asks for no camera, microphone or storage permission.
- **Ships TypeScript source, no build step.** Metro compiles it along with your app, which is the normal pattern for a React Native library. If you run Jest, add the package to `transformIgnorePatterns`:
  ```js
  transformIgnorePatterns: ['node_modules/(?!(react-native|@keyda/bot-react-native)/)'],
  ```

## Privacy

The SDK itself collects nothing and sends nothing anywhere: it loads one URL. The chat page talks to Keyda's API to answer questions, and stores a conversation id in the WebView's DOM storage so a visitor's thread survives closing the app. No device identifier is read, generated or transmitted by this package.

## Licence

MIT — see [LICENSE](LICENSE).
