/**
 * @keyda/bot-capacitor — the full-screen surface.
 *
 * Opens `{baseUrl}/chat/{clientId}`, the same hosted chat page every Keyda
 * SDK loads, as a screen over your app. See CONTRACT.md in this repository
 * for why there is one hosted page rather than a native chat per platform.
 *
 * There is no native code and no custom WebView here, deliberately. Handing
 * the URL to `@capacitor/browser` means the system browser view
 * (SFSafariViewController on iOS, Custom Tabs on Android) is what renders it,
 * and that view already satisfies the parts of the contract a hand-rolled
 * WebView gets wrong: JavaScript and DOM storage on, the keyboard never
 * covering the input, safe areas respected, and — the one that costs a
 * customer their conversation — a way back. The chat page carries a real
 * "Powered by Keyda" link; in a bare WebView, tapping it replaces the
 * conversation with a marketing site and there is no Back button to return.
 * In a system browser view there is one, plus the address bar showing which
 * site they are on.
 *
 * Most Ionic apps do not want this at all. See `embedWidget()` and the README.
 */
// The `.js` on these relative specifiers is deliberate and required. The ESM
// build is published with `{"type":"module"}` beside it, and Node's ESM loader
// does no extension guessing: extensionless output throws ERR_MODULE_NOT_FOUND
// on `import '@keyda/bot-capacitor'` from Node — an Angular Universal or any
// other prerender step, which `embedWidget()` explicitly supports. TypeScript
// resolves `./config.js` to `./config.ts` at build time, so this costs nothing.
import { assertClientId, chatUrl, normaliseBaseUrl, warn } from './config.js';

export { DEFAULT_BASE_URL, chatUrl } from './config.js';
export * from './embed.js';

export interface KeydaBotOptions {
  /** From Install in the Keyda Business dashboard: `kb_live_…`. */
  clientId: string;
  /** Defaults to `https://keyda.in/business`. Set it for staging or a self-host. */
  baseUrl?: string;
}

/**
 * The slice of `@capacitor/browser` this package uses.
 *
 * Declared structurally instead of imported. `@capacitor/browser` is an
 * OPTIONAL peer dependency, and a type imported from a package the app never
 * installed fails the app's own `tsc` run — the optional dependency would not
 * be optional in any way that mattered.
 */
interface CapacitorBrowserLike {
  open(options: { url: string; presentationStyle?: 'fullscreen' | 'popover' }): Promise<void>;
  close(): Promise<void>;
  addListener(
    eventName: 'browserFinished',
    listener: () => void,
  ): PluginListenerLike | Promise<PluginListenerLike>;
}

interface PluginListenerLike {
  remove(): void | Promise<void>;
}

/** How the current chat surface was presented, which decides what we can observe. */
type Surface =
  /** `@capacitor/browser`. Closable on iOS, and its dismissal is observable. */
  | 'capacitor-browser'
  /** A window we hold a handle to. Closable, and `closed` tells us the truth. */
  | 'window'
  /** Handed to the OS with no handle back. It opened; we can see nothing else. */
  | 'handed-off';

let config: { clientId: string; baseUrl: string } | null = null;
let surface: Surface | null = null;
let popup: Window | null = null;
let presented = false;
let finishedListenerAttached = false;
// One self-registration attempt per app run, and the proxy it produced.
// `registerPlugin` warns to the console when a name is already claimed, and
// close() resolves the plugin again on every call.
let registrationAttempted = false;
let selfRegistered: CapacitorBrowserLike | null = null;

function capacitorBridge(): Record<string, any> | null {
  if (typeof window === 'undefined') return null;
  const bridge = (window as unknown as { Capacitor?: Record<string, any> }).Capacitor;
  return bridge ?? null;
}

/**
 * Finds the Browser plugin on the Capacitor bridge, synchronously.
 *
 * Not `await import('@capacitor/browser')`, for two reasons that both bite:
 *
 *  1. an import statement — static or dynamic — still has to RESOLVE at build
 *     time. Vite and webpack fail or warn loudly for every app that did not
 *     install the optional peer, which is most of them;
 *  2. this lookup returns in the same tick, so the `window.open` fallback below
 *     still runs inside the click that triggered it. Any `await` before
 *     `window.open` spends the user gesture and the browser blocks the popup.
 *
 * Returns null on the web unless the app imported `@capacitor/browser`
 * somewhere (importing it is what registers its web implementation) — which is
 * fine, because on the web a new tab is the better surface anyway.
 */
function resolveBrowser(): CapacitorBrowserLike | null {
  const bridge = capacitorBridge();
  if (!bridge) return null;

  const registered = bridge.Plugins?.Browser;
  if (registered && typeof registered.open === 'function') return registered as CapacitorBrowserLike;

  // Installed, synced, and still not on the bridge — the case the README's
  // install line produces. `Capacitor.Plugins.Browser` is written by the
  // plugin package's own `registerPlugin('Browser')` call, which only runs if
  // the APP imports @capacitor/browser somewhere; an app that installed it for
  // this SDK has no reason to import it, so `npm i @capacitor/browser && npx
  // cap sync` alone left us silently on the window.open path — no close(), no
  // isShowing. So register it ourselves.
  //
  // Only on a native platform, and only when `PluginHeaders` says the native
  // side is really there. Both guards matter: registering claims the name (a
  // later import gets our proxy back plus a console warning), and our proxy
  // carries no web implementation. On native it does not need one — the
  // header routes every call to the native plugin — and on the web we never
  // register, so an app that does import the plugin still gets its own.
  if (selfRegistered) return selfRegistered;
  if (registrationAttempted || !isNativePlatform()) return null;
  registrationAttempted = true;
  try {
    if (typeof bridge.registerPlugin !== 'function') return null;
    const headers = bridge.PluginHeaders;
    if (!Array.isArray(headers) || !headers.some((h) => h && h.name === 'Browser')) return null;
    const plugin = bridge.registerPlugin('Browser');
    if (!plugin || typeof plugin.open !== 'function') return null;
    selfRegistered = plugin as CapacitorBrowserLike;
    return selfRegistered;
  } catch (err) {
    // A bridge that does not work the way we expect is not a reason to fail a
    // customer's tap: fall through to window.open.
    warn('could not reach the @capacitor/browser plugin', err);
    return null;
  }
}

function isNativePlatform(): boolean {
  const bridge = capacitorBridge();
  if (!bridge) return false;
  try {
    if (typeof bridge.isNativePlatform === 'function') return Boolean(bridge.isNativePlatform());
    return Boolean(bridge.isNative);
  } catch {
    return false;
  }
}

function windowStillOpen(): boolean {
  try {
    return Boolean(popup) && !popup!.closed;
  } catch {
    // `closed` is readable cross-origin, but a torn-down window can still
    // throw. Treating that as closed is the safe direction: it under-reports
    // rather than leaving `isShowing` stuck true forever.
    return false;
  }
}

function currentlyShowing(): boolean {
  if (surface === 'window') return windowStillOpen();
  return presented;
}

/**
 * Store configuration and validate the id.
 *
 * Optional — `open({ clientId })` does the same thing inline. Call this at
 * app bootstrap if you would rather a bad client id blow up on launch, where
 * you will see it, than on the first tap of the Chat button.
 */
function init(clientId: string, baseUrl?: string): void {
  config = { clientId: assertClientId(clientId), baseUrl: normaliseBaseUrl(baseUrl) };
}

/**
 * Present the chat over the host app.
 *
 * Resolves `true` when a chat surface was opened, `false` when it was not.
 * It does not reject: a host app should not have to wrap its Chat button in a
 * try/catch. When it resolves `false`, show your own "couldn't open chat, try
 * again" — that retry has to live in your UI, because this call hands off to
 * the OS and has no UI of its own to put one in.
 *
 * Deliberately not declared `async`: everything up to `window.open` on the
 * fallback path must run synchronously, or the user gesture is gone by the
 * time we ask for a window and the browser refuses it.
 */
function open(options?: KeydaBotOptions): Promise<boolean> {
  if (options) init(options.clientId, options.baseUrl);
  if (!config) {
    throw new Error(
      '[KeydaBot] no client id yet. Call KeydaBot.init("kb_live_…") once at ' +
        'startup, or pass it inline: KeydaBot.open({ clientId: "kb_live_…" }).',
    );
  }

  const url = chatUrl(config.clientId, config.baseUrl);
  const browser = resolveBrowser();
  return browser ? openViaCapacitor(browser, url) : Promise.resolve(openViaWindow(url));
}

async function openViaCapacitor(browser: CapacitorBrowserLike, url: string): Promise<boolean> {
  try {
    await browser.open({ url, presentationStyle: 'fullscreen' });
    surface = 'capacitor-browser';
    presented = true;
    await trackDismissal(browser);
    return true;
  } catch (err) {
    warn('the in-app browser refused to open; falling back to window.open', err);
    // The gesture is spent by now, so this can be blocked on the web. On a
    // device it is not a popup, it is the bridge handing the URL to the system
    // browser — and the difference between a customer reaching the chat and a
    // button that does nothing.
    return openViaWindow(url);
  }
}

/**
 * Keeps `isShowing` honest after the customer swipes the browser away.
 *
 * Without it, `isShowing` stays true forever and a host app that gates its
 * Chat button on it never lights up again. Attached once and never removed:
 * this module is a singleton for the app's lifetime, so there is exactly one
 * listener and nothing to leak.
 */
async function trackDismissal(browser: CapacitorBrowserLike): Promise<void> {
  if (finishedListenerAttached) return;
  finishedListenerAttached = true;
  try {
    await browser.addListener('browserFinished', () => {
      presented = false;
      surface = null;
    });
  } catch (err) {
    // Reset the flag so a later open() tries again rather than giving up on
    // dismissal tracking for the whole session.
    finishedListenerAttached = false;
    warn('could not observe browser dismissal; isShowing may over-report', err);
  }
}

function openViaWindow(url: string): boolean {
  if (typeof window === 'undefined' || typeof window.open !== 'function') {
    warn('no window to open the chat in (server-side rendering?)');
    return false;
  }

  const handle = window.open(url, '_blank');
  if (handle) {
    try {
      // Sever the back-reference without passing the "noopener" feature: that
      // feature makes window.open return null, and this handle is the only
      // thing that can ever make close() work. The chat page links out, so
      // whatever the customer reaches from there must not hold a reference
      // into the host app's window.
      handle.opener = null;
    } catch {
      // Cross-origin already denied it the reference. Nothing to do.
    }
    popup = handle;
    surface = 'window';
    presented = true;
    return true;
  }

  // Null handle means one of two very different things, and the Capacitor
  // bridge is what tells them apart.
  if (isNativePlatform()) {
    // The bridge took the URL and opened the system browser. It succeeded; we
    // simply cannot see the result, so isShowing reports false rather than
    // guessing. Install @capacitor/browser to get an observable, closable
    // surface instead.
    surface = 'handed-off';
    presented = false;
    popup = null;
    return true;
  }

  warn(
    'the browser blocked window.open. Call KeydaBot.open() directly from the ' +
      'click handler — an await before it spends the user gesture.',
  );
  return false;
}

/**
 * Close the chat.
 *
 * Resolves `true` only when the surface actually went away. It resolves
 * `false` rather than throwing when the platform will not let us: an Android
 * Custom Tab belongs to the customer's Back gesture, not to the app that
 * launched it, and a URL handed to the system browser has left this process
 * entirely. Both are platform facts, not conditions a host app can recover
 * from, so neither is worth an exception.
 */
function close(): Promise<boolean> {
  if (surface === 'window') {
    try {
      popup?.close();
    } catch {
      // A cross-origin window that navigated away can refuse. Fall through to
      // the check below, which reports what actually happened.
    }
    const closed = !windowStillOpen();
    if (closed) {
      popup = null;
      presented = false;
      surface = null;
    }
    return Promise.resolve(closed);
  }

  if (surface === 'capacitor-browser') {
    const browser = resolveBrowser();
    if (!browser) return Promise.resolve(false);
    return browser
      .close()
      .then(() => {
        presented = false;
        surface = null;
        return true;
      })
      .catch((err: unknown) => {
        warn('the platform would not close the in-app browser', err);
        return false;
      });
  }

  return Promise.resolve(false);
}

/**
 * The public surface. `show`/`dismiss`/`isShowing` are the names CONTRACT.md
 * uses across every Keyda SDK; `open`/`close`/`isOpen` are the same three
 * operations under the names a JavaScript caller expects — and the names
 * `widget.js` already uses on `window.KeydaBot`. They are the same functions,
 * not variants.
 */
export const KeydaBot = {
  init,
  open,
  show: open,
  close,
  dismiss: close,
  get isOpen(): boolean {
    return currentlyShowing();
  },
  get isShowing(): boolean {
    return currentlyShowing();
  },
};

export default KeydaBot;
