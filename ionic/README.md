# @keyda/bot-capacitor

**Most Ionic apps should just use the script tag.** An Ionic or Capacitor app is
already a web view, so the plain website widget runs inside it unchanged. No npm
package, no plugin, no native build step:

```html
<!-- src/index.html, before </body> -->
<script src="https://keyda.in/business/widget.js"
        data-key="kb_live_YOUR_CLIENT_ID" async></script>
```

Rebuild, run, and the launcher is there. That is the whole integration, and for
most apps it is the better one: the chat floats over your own screens, your
navigation keeps working behind it, and there is nothing to keep in sync.

This package exists for one case the script tag does not cover — when you want
the chat presented as a **separate full-screen surface** over your app rather
than embedded in your own DOM. It also ships a typed helper for the script tag
above, because that is still the right answer for most apps.

## What this actually is

Every Keyda SDK is a thin wrapper around one hosted chat page:

```
{baseUrl}/chat/{clientId}      baseUrl defaults to https://keyda.in/business
```

There is no chat UI in this package. There is no native code in it either. The
full-screen surface hands that URL to the system browser view
(SFSafariViewController on iOS, Custom Tabs on Android) and the embedded surface
injects the same `widget.js` a Keyda customer pastes into a website. Both render
the one hosted chat page, which is why a change an owner makes in their
dashboard is live in your app immediately, with no release from you.

If "it's a web view" is a dealbreaker, it is better to know now than after you
ship. [CONTRACT.md](../CONTRACT.md) explains the trade in full.

## Install

```bash
npm install @keyda/bot-capacitor
```

Zero dependencies. For the full-screen surface, also install the optional peer:

```bash
npm install @capacitor/browser && npx cap sync
```

It is optional in the real sense — without it the package falls back to
`window.open` and still works, with the limits noted under
[Full-screen](#option-2-full-screen) below.

There is nothing to import: on a device, `npx cap sync` is enough, and this
package picks the plugin up off the Capacitor bridge itself. (On the web there
is no native plugin to find, so the chat opens in a new tab either way — unless
your own code imports `@capacitor/browser`, which registers its web
implementation.)

Get your client id from **Install** in the
[Keyda Business dashboard](https://keyda.in/business/app/).

## Option 1: embedded (recommended)

The typed equivalent of the script tag, for when you would rather configure the
client id in code than in `index.html`:

```ts
import { embedWidget } from '@keyda/bot-capacitor';

// Once, at app bootstrap.
await embedWidget({ clientId: 'kb_live_YOUR_CLIENT_ID' });
```

It resolves `true` when the script loaded, `false` if it could not be fetched.
It never throws for a network failure.

To open the chat from your own button instead of the floating launcher:

```ts
import { getEmbeddedWidget } from '@keyda/bot-capacitor';

getEmbeddedWidget()?.open();
```

Two things about the embedded widget that are easy to trip over:

- **It mounts once per page load and has no teardown.** Embed it at bootstrap,
  not inside a component that unmounts on navigation. There is no API to remove
  it again, and this package does not pretend otherwise.
- **`window.KeydaBot` is not this package's `KeydaBot`.** The widget publishes
  its own controls on that global. `getEmbeddedWidget()` is the typed way to
  reach them. The `KeydaBot` you import drives the full-screen surface, and the
  two share no state.

## Option 2: full-screen

```ts
import { KeydaBot } from '@keyda/bot-capacitor';

KeydaBot.init('kb_live_YOUR_CLIENT_ID');        // once, at bootstrap

// From a button:
const opened = await KeydaBot.open();
if (!opened) {
  // Show your own "couldn't open chat, try again". This call hands off to the
  // OS and has no UI of its own to put a retry in.
}
```

`open()` also takes the config inline, so `init()` is optional:

```ts
await KeydaBot.open({ clientId: 'kb_live_…', baseUrl: 'https://staging.keyda.in' });
```

### Which path it takes

| Situation | Surface | `close()` | `isShowing` |
|---|---|---|---|
| `@capacitor/browser` installed, iOS | SFSafariViewController | works | accurate |
| `@capacitor/browser` installed, Android | Custom Tabs | see below | accurate |
| No plugin, on device | system browser, via the Capacitor bridge | no | always `false` |
| No plugin, web / `ionic serve` | new tab | works | accurate |

**Android `close()`.** A Custom Tab belongs to the customer's Back gesture, not
to the app that launched it. `close()` resolves `false` there instead of
throwing. Do not build UI that depends on dismissing the chat programmatically
on Android.

**Without the plugin, on device**, the URL leaves your process and there is no
handle back. `open()` resolves `true` because it did open, and `isShowing`
reports `false` because the honest answer is that we cannot see it any more.
Install `@capacitor/browser` if you need either of those to mean more.

**On the web**, `open()` must be called directly from the click handler. An
`await` before it spends the user gesture and the browser blocks the popup;
`open()` resolves `false` and says so in the console.

## API

```ts
KeydaBot.init(clientId: string, baseUrl?: string): void
KeydaBot.open(options?: { clientId, baseUrl }): Promise<boolean>   // alias: show()
KeydaBot.close(): Promise<boolean>                                // alias: dismiss()
KeydaBot.isOpen: boolean                                          // alias: isShowing

embedWidget(options: { clientId, baseUrl? }): Promise<boolean>
getEmbeddedWidget(): EmbeddedWidget | null
chatUrl(clientId: string, baseUrl?: string): string
```

`show`/`dismiss`/`isShowing` are the names every Keyda SDK uses;
`open`/`close`/`isOpen` are the same three operations under the names a
JavaScript caller expects. They are the same functions, not variants.

That is the entire surface. There is no `sendMessage`, no unread count and no
`identify` call, because there is nothing behind them yet on the server. A
method that does not work end to end is worse than a missing one.

An invalid `clientId` throws immediately — it must match
`kb_live_` + 8-48 hex characters — and so does `open()` called before any
client id has been given. Those two are the only things in this package that
throw, and it is deliberate: both are mistakes in your own source that fail
identically on every run, so they surface on your first launch rather than in
front of a customer. Runtime failures (offline, blocked, refused) are all
reported by return value.

## Things this package cannot do for you

### The keyboard, on the embedded path

The single most common web-view chat defect is the keyboard covering the input.
On the full-screen path the system browser view handles it and there is nothing
to configure. On the **embedded** path it is your app's window, so it is your
setting:

- **iOS** — leave `@capacitor/keyboard`'s `resize` at its default (`native`).
  Setting `resize: 'none'` leaves the keyboard over the chat input.
- **Android** — keep `adjustResize` on the activity, which is Capacitor's
  default. Changing it to `adjustPan` for some other screen affects this one.

### Safe areas, on the embedded path

`widget.js` fills the viewport it is given and adds no inset padding of its own.
On a phone screen (520px and under) the chat panel goes edge to edge. In a
default Capacitor app the web view is already laid out inside the safe area, so
this is fine. If you have gone edge-to-edge — `viewport-fit=cover` with a
transparent status bar — check the panel header and the launcher on a notched
device, because the widget will go edge-to-edge with you.

The full-screen path is unaffected: the system browser view draws its own chrome
and handles insets itself.

### Authorized domains

If the bot owner has set **Authorized Domains** in the dashboard, the embedded
widget has to satisfy it. A Capacitor web view reports its origin as
`capacitor://localhost` (iOS) or `https://localhost` (Android), and `localhost`
always passes — so a default Capacitor app works with no dashboard change.

If you set `server.hostname` in `capacitor.config.ts`, your web view stops
reporting `localhost` and starts reporting that hostname. Add it to Authorized
Domains, or the widget loads and then silently refuses to mount.

The full-screen path is unaffected — the hosted page is served by the platform
itself and is always allowed.

### Theme

The chat's theme — light, dark, or matching the visitor's device — is set once
by the bot owner in the dashboard, and the hosted page applies it. There is no
theme option on this package and no per-app override; the owner's setting
reaches every surface at once, which is the point of a single hosted renderer.

- **Embedded path** — `widget.js` runs on your page and is themed fully,
  including "Match the visitor", which follows the device's colour scheme.
- **Full-screen path** — the chat inside the system browser sheet is themed
  by the same setting. The sheet's own chrome (the toolbar and the Done/close
  control) is the platform's and follows the device, not the bot: a system
  browser view has no bridge for the page to announce its theme through, so
  this package cannot make an "Always dark" bot's sheet chrome dark on a
  light device. The native Android, iOS, React Native and Flutter SDKs do
  match their chrome to the page; if that matters to you, they are the
  better fit.

### Conversation continuity

The chat keeps its conversation in DOM storage, per client id, for 24 hours.
The embedded widget stores that in **your app's** web view; the full-screen
surface stores it in the **system browser's**. They are separate jars, so a
conversation started one way does not continue in the other. Pick one surface
per app rather than offering both.

## Limitations

Stated plainly, because discovering these after shipping is worse:

- **Not offline-capable.** It is a hosted page. No connection, no chat.
- **No push notifications.** If a customer leaves the chat, nothing brings them
  back.
- **No theme API.** Theme and accent colour come from the dashboard and apply
  everywhere at once; there is no per-app override. See [Theme](#theme) for
  what the system browser sheet does and does not follow.
- **No teardown for the embedded widget.** It mounts once per page load.
- **`close()` is unreliable on Android**, and impossible without
  `@capacitor/browser`. See [Which path it takes](#which-path-it-takes).
- **No analytics and no device identifiers.** Nothing here observes your users.
  That is a design constraint, not an oversight.

On outbound links: the chat now carries many of them, not just the
"Powered by Keyda" footer — every URL or markdown link in a bot answer is
rendered as an anchor with `target="_blank" rel="noopener noreferrer"`. On the
full-screen path those open outside the chat by construction (the system
browser owns the surface). On the embedded path, what happens to a
`target="_blank"` tap is your shell's external-navigation policy, not this
package's: stock Capacitor hands it to the system browser, but a Cordova or
hand-rolled WebView shell may drop it — if links in answers do nothing in your
app, that is where to look.

## Licence

MIT — see [LICENSE](../LICENSE) at the repository root.
