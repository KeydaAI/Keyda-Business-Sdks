/**
 * @keyda/bot-react-native
 *
 * A Modal + WebView around the hosted chat page at {baseUrl}/chat/{clientId}.
 * There is one chat renderer — the web widget the platform serves — and every
 * Keyda SDK loads it, so an owner's dashboard change (welcome message, accent,
 * knowledge) reaches this app with no app release. See CONTRACT.md in the repo.
 */
import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  ActivityIndicator,
  BackHandler,
  Dimensions,
  Keyboard,
  KeyboardAvoidingView,
  Linking,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
  useColorScheme,
  useWindowDimensions,
} from 'react-native';
import type {LayoutChangeEvent, StyleProp, ViewStyle} from 'react-native';
import {WebView} from 'react-native-webview';
import {repliesFor, useReplyStore} from './replies';
import type {KeydaBotReplies, KeydaBotRepliesOptions, KeydaBotStorage} from './replies';
import {cleanVisitor, isLoneSurrogate} from './visitor';
import type {KeydaBotVisitor} from './visitor';

export type {KeydaBotReplies, KeydaBotRepliesOptions, KeydaBotStorage, KeydaBotVisitor};

const DEFAULT_BASE_URL = 'https://keyda.in/business';

/** This package's version — `version` in package.json, which the suite holds it to. */
const SDK_VERSION = '0.2.0';

/** The shape the platform issues. Kept identical to the server's own check. */
const CLIENT_ID = /^kb_live_[0-9a-f]{8,48}$/;

/**
 * Schemes that belong to another app rather than to this WebView, and the only
 * ones this SDK will hand to the OS. `upi` is on the list because the chat
 * page does emit payment links, and dropping them here would break a pay-us
 * link that works on every other Keyda surface. (The iOS and Flutter SDKs take
 * the opposite approach — they name the schemes the WebView uses to talk to
 * ITSELF and pass everything else out — because on those platforms the system
 * refuses an unhandled scheme quietly. On Android an `intent://` names an
 * arbitrary component, so this side needs the allowlist.)
 *
 * An allowlist rather than a denylist, so a scheme nobody vetted cannot arrive
 * later and be launched. `intent://` is the one that matters: on Android it
 * names an arbitrary component and extras, and the chat's answers are partly
 * generated from content this SDK does not control.
 */
const EXTERNAL_SCHEME = /^(https?|mailto|tel|sms|whatsapp|upi|geo|maps):/i;

/**
 * True for an id the chat page will actually accept. Exported so an app that
 * loads its client id from a remote config can check it before rendering,
 * rather than catching the throw from `buildChatUrl`.
 */
export function isValidClientId(clientId: unknown): boolean {
  return typeof clientId === 'string' && CLIENT_ID.test(clientId);
}

/**
 * Lower-cases scheme and host only. A baseUrl typed `HTTPS://Business.Keyda.in`
 * would otherwise never prefix-match the all-lowercase URL the WebView reports
 * back, and every navigation — including the chat's own first load — would be
 * treated as a link to somewhere else.
 */
function canonical(url: string): string {
  return url.replace(/^[a-z][a-z0-9+.-]*:\/\/[^/?#]*/i, m => m.toLowerCase());
}

/**
 * Build the URL this SDK opens. Throws on a malformed client id or baseUrl:
 * both can only be a mistake in the integration, and the alternative is a
 * "This chat link is not valid" page appearing in front of a paying customer.
 * A throw here lands on the developer's screen the first time they run the app.
 */
export function buildChatUrl(clientId: string, baseUrl: string = DEFAULT_BASE_URL): string {
  if (!isValidClientId(clientId)) {
    throw new Error(
      '[KeydaBot] Invalid clientId ' +
        JSON.stringify(clientId) +
        '. Expected kb_live_ followed by 8-48 hex characters — copy it from Install in the Keyda Business dashboard.',
    );
  }
  // Trailing slashes are the common paste artefact; left in place they produce
  // //chat/ and a 404.
  const base = String(baseUrl == null ? '' : baseUrl).trim().replace(/\/+$/, '');
  // Anchored at BOTH ends, and a query or fragment is refused rather than
  // tolerated: this function appends `/chat/{id}`, so a baseUrl of
  // "https://host?x=1" would build "https://host?x=1/chat/kb_live_…" — a URL
  // that is not a mistake anyone can see, and that fails as a 404 in front of
  // a customer. A path prefix IS kept, so a self-host mounted at
  // https://acme.example/support resolves to /support/chat/{id}.
  if (!/^https?:\/\/[^/?#]+(\/[^?#]*)?$/i.test(base)) {
    throw new Error(
      '[KeydaBot] Invalid baseUrl ' +
        JSON.stringify(baseUrl) +
        '. Expected an absolute http(s) URL — an origin, optionally with a path prefix, and no query string or #fragment — such as ' +
        DEFAULT_BASE_URL +
        '.',
    );
  }
  return canonical(base + '/chat/' + clientId);
}

/**
 * Is this navigation the bot's own chat page, or somewhere else?
 *
 * The chat carries a real "Powered by Keyda" link, and it points at the SAME
 * origin as the chat itself — so an origin comparison would happily let it load
 * in place, replacing the customer's conversation with a marketing page inside
 * a Modal that has no back button. Only the chat URL (and its query, fragment
 * or sub-path) may navigate here; everything else leaves for the browser.
 */
function staysInChat(url: string, chatUrl: string): boolean {
  const here = canonical(url);
  if (here === chatUrl) {
    return true;
  }
  if (!here.startsWith(chatUrl)) {
    return false;
  }
  const next = here.charAt(chatUrl.length);
  return next === '?' || next === '#' || next === '/';
}

/**
 * The single door out of this SDK to the OS, and so the only place the scheme
 * allowlist is applied — because there are TWO routes to it. WKWebView delivers
 * `onOpenWindow` for a `window.open` or a `target="_blank"` link BEFORE
 * `onShouldStartLoadWithRequest` runs (it cancels the navigation and fires the
 * open-window event instead), so a check that lived only in the navigation
 * handler would never see that URL at all.
 *
 * Anything outside the allowlist — `intent://`, `javascript:`, a private
 * scheme — is refused in silence. The chat page never produces one, and handing
 * an unvetted URL to the OS is not worth the risk.
 *
 * Linking.openURL rejects when no installed app claims the scheme — a `tel:`
 * on a Wi-Fi tablet, say. An unhandled rejection in the host app is exactly the
 * kind of thing this SDK must never cause, so the failure stays swallowed: the
 * customer's chat is still on screen and untouched.
 */
function openExternally(url: string): void {
  if (!EXTERNAL_SCHEME.test(url)) {
    return;
  }
  Linking.openURL(url).catch(() => {});
}

export interface KeydaBotProps {
  /** From Install in the Keyda Business dashboard: kb_live_ + 8-48 hex chars. */
  clientId: string;
  /** Override for self-hosting or staging. Defaults to https://keyda.in/business */
  baseUrl?: string;
  /** Present the chat over the app. */
  visible: boolean;
  /** Called when the customer closes the chat, including via Android back. */
  onClose: () => void;
  /**
   * Optional: put in the chat's message box for the customer to send — they
   * still tap send. Read when the chat opens (it travels in the URL's
   * #fragment, never in a server log); a new value while it is open replaces
   * what is in the box. Up to 500 characters, as one line: the chat joins
   * lines and collapses runs of spaces.
   */
  question?: string;
  /**
   * Set by `useKeydaBot().show()`: a new number puts `question` in the box
   * again even when it is the same text (the customer may have edited it).
   */
  questionKey?: number;
  /** Optional: your signed-in customer; see `KeydaBotVisitor`. */
  visitor?: KeydaBotVisitor;
}

type Status = 'loading' | 'ready' | 'failed';

type Scheme = 'light' | 'dark';

/**
 * The chat page's own surface colours, per scheme. The hosted widget resolves
 * the owner's Theme setting itself and announces it (rule 7 in CONTRACT.md);
 * light chrome around a dark chat (white bar, dark status-bar text) would
 * frame it like a broken page. Kept identical to the page: #f7f8fc is the light
 * page background, #0b1220 the dark <html> background — the colour of the
 * page's FIRST paint, which is what the loading cover has to match.
 */
const PALETTE = {
  light: {bg: '#f7f8fc', glyph: '#4a5570', title: '#1f2740', body: '#4a5570', bar: 'dark-content' as const},
  dark: {bg: '#0b1220', glyph: '#cbd5e1', title: '#e2e8f0', body: '#94a3b8', bar: 'light-content' as const},
};

/**
 * The scheme a message from the page names, or null for anything else.
 *
 * The page posts `{"type":"keyda:theme","mode":"light"|"dark",...}` through
 * window.ReactNativeWebView.postMessage as early as its <head> runs, and again
 * when a "Match the visitor" bot flips with the OS. Anything else arriving on
 * that channel — another message type, a non-JSON string, a future field
 * shape — is ignored rather than guessed at, and never thrown on: onMessage
 * runs inside the host app, which rule 6 says this SDK must not crash.
 */
function themeFromMessage(data: unknown): Scheme | null {
  if (typeof data !== 'string') {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(data);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) {
    return null;
  }
  const msg = parsed as {type?: unknown; mode?: unknown};
  if (msg.type !== 'keyda:theme') {
    return null;
  }
  return msg.mode === 'dark' ? 'dark' : msg.mode === 'light' ? 'light' : null;
}

/**
 * Android back over a live chat (CONTRACT rule 10). The page can have a sheet
 * open over the conversation — an item over the menu, the cart, a booking —
 * and back is the customer closing THAT. The page's `KeydaBot.back()` takes
 * off the top sheet and answers whether there was one; the answer comes back
 * as a `keyda:back` message. A page too old to have `back()`, or one that
 * throws, answers false and the chat closes as it always did. The trailing
 * `true;` is react-native-webview's own advice for injected scripts.
 */
const BACK_SCRIPT =
  "(function(){var h=false;try{h=!!(window.KeydaBot&&typeof window.KeydaBot.back==='function'&&window.KeydaBot.back());}catch(e){}" +
  "window.ReactNativeWebView.postMessage(JSON.stringify({type:'keyda:back',handled:h}));})();true;";

/** How long back waits for the page's answer before closing the chat anyway. */
const BACK_ANSWER_MS = 500;

/** The page's answer to BACK_SCRIPT: true / false, or null for any other message. */
function backAnswerFromMessage(data: unknown): boolean | null {
  if (typeof data !== 'string' || data.indexOf('keyda:back') < 0) {
    return null;
  }
  try {
    const msg = JSON.parse(data) as {type?: unknown; handled?: unknown};
    return msg && msg.type === 'keyda:back' ? msg.handled === true : null;
  } catch {
    return null;
  }
}

/** The page takes up to 500 characters; anything longer is cut, not refused. */
const QUESTION_MAX = 500;

/**
 * Trimmed, cut at 500 CHARACTERS — not UTF-16 units, which split an emoji in
 * half — and without lone surrogates. Either kind of half character made
 * encodeURIComponent throw a URIError from inside render, which took the host
 * app's whole React tree down with it.
 */
function cleanQuestion(question: string | null | undefined): string {
  if (typeof question !== 'string') return '';
  return Array.from(question.trim())
    .filter(c => !isLoneSurrogate(c))
    .slice(0, QUESTION_MAX)
    .join('');
}

/** Never throws: a value that cannot be encoded is left out, not raised. */
function encodePart(value: string): string {
  try {
    return encodeURIComponent(value);
  } catch {
    return '';
  }
}

/**
 * The chat URL with its start in the #fragment — the question, and the
 * visitor's details: the page reads it as it loads and takes it off the
 * address. A fragment is never sent to a server.
 */
function withStart(chatUrl: string, question: string, visitor: Required<KeydaBotVisitor> | null): string {
  const parts: string[] = [];
  const q = question ? encodePart(question) : '';
  if (q) parts.push('q=' + q);
  if (visitor) {
    if (visitor.name) parts.push('name=' + encodePart(visitor.name));
    if (visitor.phone) parts.push('phone=' + encodePart(visitor.phone));
    if (visitor.email) parts.push('email=' + encodePart(visitor.email));
  }
  return parts.length ? chatUrl + '#' + parts.join('&') : chatUrl;
}

/** Hands the page a changed visitor (KeydaBot.setVisitor on the page). */
function visitorScript(visitor: Required<KeydaBotVisitor> | null): string {
  return (
    '(function(){try{window.KeydaBot&&window.KeydaBot.setVisitor&&window.KeydaBot.setVisitor(' +
    JSON.stringify(visitor ?? {}) +
    ');}catch(e){}})();true;'
  );
}

/** The chats waiting for a reply — `{"type":"keyda:waits","waits":[…]}` — or null. */
function waitsFromMessage(data: unknown): unknown[] | null {
  if (typeof data !== 'string' || data.indexOf('keyda:waits') < 0) return null;
  try {
    const msg = JSON.parse(data) as {type?: unknown; waits?: unknown};
    return msg && msg.type === 'keyda:waits' && Array.isArray(msg.waits) ? msg.waits : null;
  } catch {
    return null;
  }
}

/** Puts a question in the live chat's composer (KeydaBot.prefill on the page). */
function prefillScript(question: string): string {
  return (
    '(function(){try{window.KeydaBot&&window.KeydaBot.prefill&&window.KeydaBot.prefill(' +
    JSON.stringify(question) +
    ');}catch(e){}})();true;'
  );
}

/** Closes the page's top sheet without asking for an answer (the sheet count is known). */
const BACK_ONLY_SCRIPT = "(function(){try{window.KeydaBot&&window.KeydaBot.back&&window.KeydaBot.back();}catch(e){}})();true;";

/**
 * The page's sheet count — `{"type":"keyda:sheets","open":n}` (CONTRACT rule
 * 10) — or null for any other message.
 */
function sheetsFromMessage(data: unknown): number | null {
  if (typeof data !== 'string' || data.indexOf('keyda:sheets') < 0) {
    return null;
  }
  try {
    const msg = JSON.parse(data) as {type?: unknown; open?: unknown};
    if (!msg || msg.type !== 'keyda:sheets' || typeof msg.open !== 'number') return null;
    return msg.open >= 0 && msg.open <= 64 ? Math.floor(msg.open) : null;
  } catch {
    return null;
  }
}

/**
 * The navigation bar's height once it is known: the last keyboard on screen
 * left exactly that much below it. Kept for the life of the app, so the next
 * open starts right.
 */
let learnedNavInset: number | null = null;

/**
 * The navigation bar's height before any keyboard has shown. From the app's
 * own react-native-safe-area-context when it has one (React Navigation and
 * Expo apps do), read through its native module so this package imports
 * nothing and needs nothing installed; otherwise 48 — three-button
 * navigation's height, which also clears gesture navigation's 24.
 */
function initialNavInset(): number {
  if (learnedNavInset !== null) return learnedNavInset;
  try {
    const mod: any = TurboModuleRegistry.get('RNCSafeAreaContext');
    const constants = mod && typeof mod.getConstants === 'function' ? mod.getConstants() : mod;
    const bottom = constants?.initialWindowMetrics?.insets?.bottom;
    // Launched on its side, a three-button bar is beside the screen and the
    // bottom reads 0: no room for it in the next portrait chat. Not trusted.
    const frame = constants?.initialWindowMetrics?.frame;
    const landscape = frame && typeof frame.width === 'number' && frame.width > frame.height;
    if (!landscape && typeof bottom === 'number' && bottom >= 0 && bottom < 120) return bottom;
  } catch {
    // Not installed, or a shape we do not know: the fallback below is safe.
  }
  return 48;
}

/**
 * Android's system bars and keyboard, for a Modal drawn edge-to-edge.
 *
 * React Native 0.81+ makes an app that targets Android 15 or later
 * edge-to-edge — every app Play accepts now targets 16 — and then draws a
 * Modal under BOTH system bars whatever statusBarTranslucent says, and the
 * window stops resizing for the keyboard. Core SafeAreaView pads on iOS only.
 * Without this, on Android 16 the close button sat in the status bar,
 * "Powered by Keyda" under the gesture bar, and the keyboard covered the
 * message box.
 *
 * Measured rather than assumed: the container counts as edge-to-edge only
 * when it is as tall as the screen. An app that is not keeps the behaviour it
 * had — its window already excludes the bars and adjustResize lifts the input,
 * so padding here as well would count them twice.
 */
function useAndroidInsets(active: boolean): {
  onLayout: (e: LayoutChangeEvent) => void;
  top: number;
  bottom: number;
  left: number;
  right: number;
  edgeToEdge: boolean;
} {
  const [edgeToEdge, setEdgeToEdge] = useState(false);
  const [keyboardTop, setKeyboardTop] = useState<number | null>(null);
  const [nav, setNav] = useState(initialNavInset);
  const dims = useWindowDimensions();

  useEffect(() => {
    if (Platform.OS !== 'android' || !active) return undefined;
    const shown = Keyboard.addListener('keyboardDidShow', (e) => {
      const top = e.endCoordinates.screenY;
      setKeyboardTop(top);
      // What is left under the keyboard is the navigation bar — the one
      // moment core React Native says how tall it is. Only from a keyboard as
      // wide as the screen: in landscape a three-button bar sits BESIDE the
      // keyboard, nothing is under it, and learning 0 there left the next
      // portrait chat with no room for the bar at all.
      const screen = Dimensions.get('screen');
      const below = screen.height - top - e.endCoordinates.height;
      const fullWidth = e.endCoordinates.width >= screen.width - 1;
      if (fullWidth && below >= 0 && below < 120) {
        learnedNavInset = below;
        setNav(below);
      }
    });
    const hidden = Keyboard.addListener('keyboardDidHide', () => setKeyboardTop(null));
    return () => {
      shown.remove();
      hidden.remove();
      // The chat can close with the keyboard up, and its keyboardDidHide then
      // arrives after this listener is gone: a stale keyboard height would
      // leave a keyboard-sized blank band under the next chat.
      setKeyboardTop(null);
    };
  }, [active]);

  const onLayout = useCallback((e: LayoutChangeEvent) => {
    if (Platform.OS !== 'android') return;
    setEdgeToEdge(e.nativeEvent.layout.height >= Dimensions.get('screen').height - 1);
  }, []);

  if (Platform.OS !== 'android' || !edgeToEdge) return {onLayout, top: 0, bottom: 0, left: 0, right: 0, edgeToEdge: false};
  const below = keyboardTop === null ? nav : Math.max(nav, Dimensions.get('screen').height - keyboardTop);
  // A phone on its side: a three-button navigation bar moves to one side and
  // a camera cutout can be on either, and core React Native reports neither
  // (its window is the whole screen). Both sides keep the width of that bar,
  // 48dp, clear. A tablet keeps its bar at the bottom.
  const side = dims.width > dims.height && Math.min(dims.width, dims.height) < 600 ? SIDE_INSET : 0;
  return {onLayout, top: StatusBar.currentHeight ?? 0, bottom: below, left: side, right: side, edgeToEdge: true};
}

/** A three-button navigation bar's width on a phone in landscape. */
const SIDE_INSET = 48;

/**
 * True when nothing in the host app has set a status bar style through React
 * Native: its default is still `'default'` and no `<StatusBar>` of its own is
 * mounted. Read from StatusBar's internals, which have no public getter; any
 * other shape reads as "the host set one", which leaves things as they were.
 */
function hostLeftStatusBarUnstyled(): boolean {
  try {
    const sb = StatusBar as unknown as {_defaultProps?: {barStyle?: {value?: unknown}}; _propsStack?: unknown[]};
    return sb._defaultProps?.barStyle?.value === 'default' && Array.isArray(sb._propsStack) && sb._propsStack.length === 0;
  } catch {
    return false;
  }
}

type Colors = (typeof PALETTE)[Scheme];

/** Only injectJavaScript is used, so the ref is typed by that shape (see ChatSurface). */
type WebHandle = {injectJavaScript: (script: string) => void};

interface SurfaceProps {
  /** The chat URL, for deciding what stays in the chat. */
  chatUrl: string;
  /** What this WebView instance loads: the chat URL, with the start question. */
  startUrl: string;
  colors: Colors;
  status: Status;
  setStatus: React.Dispatch<React.SetStateAction<Status>>;
  /** Bumped to retry: a fresh WebView is the one retry that works in every failure mode. */
  attempt: number;
  onRetry: () => void;
  webRef: React.MutableRefObject<WebHandle | null>;
  onMessage: (data: unknown) => void;
  /** A page finished loading here, and did not fail: the first load, a Retry, a reload. */
  onLoaded: () => void;
}

/**
 * The WebView, its loading cover and its retry screen — the part `<KeydaBot />`
 * and `<KeydaBotChat />` share.
 */
function ChatSurface({chatUrl, startUrl, colors, status, setStatus, attempt, onRetry, webRef, onMessage, onLoaded}: SurfaceProps): React.ReactElement {
  // react-native-webview types its ref differently across the versions the
  // peer range allows (13: the class; 14: forwardRef<unknown>, and no ref at
  // all on its platform-neutral typings), so it is spread in rather than
  // written as ref={…}.
  const webRefProp = useMemo(() => ({ref: webRef}) as {}, [webRef]);

  const handleRequest = useCallback(
    (request: {url: string}) => {
      const url = request.url;
      if (staysInChat(url, chatUrl)) {
        return true;
      }
      // WKWebView loads about:blank while setting itself up; handing that to
      // the browser would flash an empty tab over the app.
      if (url === 'about:blank') {
        return true;
      }
      // Never navigates here. openExternally applies the scheme allowlist and
      // drops anything outside it, so a URL this WebView will not load is not
      // silently promoted into something the OS will.
      openExternally(url);
      return false;
    },
    [chatUrl],
  );

  const handleOpenWindow = useCallback((event: {nativeEvent: {targetUrl: string}}) => {
    // A window the page opens itself is by definition not the chat.
    openExternally(event.nativeEvent.targetUrl);
  }, []);

  // Whether the WebView on screen has failed. Kept here rather than read from
  // `status`, which is a render behind when onLoadEnd arrives. A WebView that
  // failed is taken down for the retry screen, so the next one starts clean.
  const failed = useRef(false);
  useEffect(() => {
    if (status !== 'failed') failed.current = false;
  }, [status]);

  const fail = useCallback(() => {
    failed.current = true;
    setStatus('failed');
  }, [setStatus]);

  const handleLoadEnd = useCallback(() => {
    // onLoadEnd fires for a failed load too, and can arrive after onError — so
    // a load that already reported an error must not be marked ready, or the
    // retry screen never appears.
    setStatus(s => (s === 'failed' ? s : 'ready'));
    if (!failed.current) onLoaded();
  }, [setStatus, onLoaded]);

  const handleError = fail;

  const handleMessage = useCallback(
    (event: {nativeEvent: {data: string}}) => onMessage(event.nativeEvent && event.nativeEvent.data),
    [onMessage],
  );

  const handleHttpError = useCallback(
    (event: {nativeEvent: {url?: string}}) => {
      // onHttpError also fires for sub-resources on iOS. A 404 on some image
      // must not replace a chat that is working; only the chat document counts.
      const url = event.nativeEvent && event.nativeEvent.url;
      if (typeof url === 'string' && staysInChat(url, chatUrl)) {
        fail();
      }
    },
    [chatUrl, fail],
  );

  // Android kills WebView renderers under memory pressure, and using that
  // WebView again takes the host app down with it. Handling the event at all
  // is what keeps the crash from happening; the retry screen mounts a new one.
  const handleProcessGone = fail;

  if (status === 'failed') {
    return (
      <View style={styles.center}>
        <Text style={[styles.errorTitle, {color: colors.title}]}>Chat didn’t load</Text>
        <Text style={[styles.errorBody, {color: colors.body}]}>Check your connection and try again.</Text>
        <Pressable onPress={onRetry} accessibilityRole="button" style={styles.retry}>
          <Text style={styles.retryLabel}>Try again</Text>
        </Pressable>
      </View>
    );
  }
  return (
    <>
      <WebView
        key={attempt}
        {...webRefProp}
        source={{uri: startUrl}}
        style={[styles.web, {backgroundColor: colors.bg}]}
        // The chat is a web app. Without JavaScript there is no chat.
        javaScriptEnabled
        // The visitor's conversation id lives in localStorage. Without
        // DOM storage every open starts a brand new conversation.
        domStorageEnabled
        // Required for the policy below to exist at all. Left at its
        // default (['http://*', 'https://*']) react-native-webview
        // intercepts every OTHER scheme itself, ahead of
        // onShouldStartLoadWithRequest, and hands it straight to
        // Linking.openURL — so handleRequest would never be consulted
        // for a tel:, a mailto:, or an intent:// the page emitted, and
        // the allowlist in openExternally would be dead code. '*' puts
        // every navigation through the handler, which is the only way
        // this SDK actually decides what leaves it.
        originWhitelist={['*']}
        onShouldStartLoadWithRequest={handleRequest}
        // Android: while multiple windows are supported, a
        // target="_blank" link — which is exactly what "Powered by
        // Keyda" is — never reaches onShouldStartLoadWithRequest and
        // does nothing at all when tapped.
        setSupportMultipleWindows={false}
        onOpenWindow={handleOpenWindow}
        // iOS: the page focuses its input without a preceding tap.
        keyboardDisplayRequiresUserAction={false}
        // iOS: the container already resizes this view for the keyboard;
        // WKWebView's own inset on top of that leaves a keyboard-high gap.
        automaticallyAdjustContentInsets={false}
        contentInsetAdjustmentBehavior="never"
        // The page is a fixed full-screen layout — Android's overscroll
        // glow on it just reads as broken.
        overScrollMode="never"
        // `KeydaBot/<version> (ReactNative)` after the platform's own
        // User-Agent, as the Android and Flutter SDKs mark theirs: a
        // version and nothing else. On Android the page reads it to know
        // this shell keeps the chat clear of the system bars, which the
        // WebView reports as safe area all the same.
        applicationNameForUserAgent={`KeydaBot/${SDK_VERSION} (ReactNative)`}
        // The page's messages: the theme (rule 7), back answers and the
        // sheet count (rule 10). Wiring onMessage is also what makes
        // window.ReactNativeWebView exist in the page at all, so it stays.
        onMessage={handleMessage}
        onLoadEnd={handleLoadEnd}
        onError={handleError}
        onHttpError={handleHttpError}
        onRenderProcessGone={handleProcessGone}
        onContentProcessDidTerminate={handleProcessGone}
      />
      {status === 'loading' ? (
        // Covers the WebView's white first frame with the page's own
        // background, so opening the chat is not a flash of white.
        <View style={[styles.cover, {backgroundColor: colors.bg}]} pointerEvents="none">
          <ActivityIndicator color={colors.body} />
        </View>
      ) : null}
    </>
  );
}

/** What a question was put in the box as: its text and the show() it came from. */
function askedAs(question: string, key: number | undefined): string {
  return `${key ?? 0}:${question}`;
}

/**
 * The start for a WebView instance: captured when it mounts (or is retried),
 * so a later change of a prop goes into the live chat instead of reloading the
 * page. The question rides only until a page has shown it: a retry must not
 * put a question the customer already sent back into the box.
 */
function useStartUrl(
  chatUrl: string,
  question: string | undefined,
  questionKey: number | undefined,
  visitor: Required<KeydaBotVisitor> | null,
  live: boolean,
  attempt: number,
  delivered: React.MutableRefObject<boolean>,
): {startUrl: string; asked: React.MutableRefObject<string>} {
  const state = useRef<{live: boolean; attempt: number; url: string}>({live: false, attempt: -1, url: chatUrl});
  const asked = useRef('');
  if (live && (!state.current.live || state.current.attempt !== attempt || !state.current.url.startsWith(chatUrl))) {
    if (!state.current.live) delivered.current = false;
    const q = delivered.current ? '' : cleanQuestion(question);
    state.current = {live: true, attempt, url: withStart(chatUrl, q, visitor)};
    asked.current = askedAs(cleanQuestion(question), questionKey);
  } else if (!live && state.current.live) {
    state.current = {...state.current, live: false};
  }
  return {startUrl: state.current.url, asked};
}

/**
 * A new question for a chat that is already up goes into its composer — a new
 * text, or the same text from a new show() (the customer may have edited it).
 */
function usePrefill(
  question: string | undefined,
  questionKey: number | undefined,
  ready: boolean,
  asked: React.MutableRefObject<string>,
  webRef: React.MutableRefObject<WebHandle | null>,
): void {
  useEffect(() => {
    const q = cleanQuestion(question);
    if (!ready || !q || askedAs(q, questionKey) === asked.current) return;
    asked.current = askedAs(q, questionKey);
    if (webRef.current) webRef.current.injectJavaScript(prefillScript(q));
  }, [question, questionKey, ready, asked, webRef]);
}

/**
 * The visitor reaches the page at every page finish — the first load, a Retry,
 * a reload — through the function this returns, and on every change while a
 * page is up. The first load's #fragment carried the details as they were when
 * it started: one set, changed or cleared while the page loaded would be lost.
 * `{}` when there is none, so a cleared visitor is cleared there too.
 */
function useVisitorUpdates(
  visitor: Required<KeydaBotVisitor> | null,
  ready: boolean,
  webRef: React.MutableRefObject<WebHandle | null>,
): () => void {
  const latest = useRef(visitor);
  latest.current = visitor;
  const key = JSON.stringify(visitor);
  useEffect(() => {
    // Only a change: the page finish below has already handed over the one
    // the page loaded with.
    if (ready && webRef.current) webRef.current.injectJavaScript(visitorScript(visitor));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return useCallback(() => {
    if (webRef.current) webRef.current.injectJavaScript(visitorScript(latest.current));
  }, [webRef]);
}

/** The chat counts as on screen for the reply check while `onScreen` holds. */
function useOnScreen(chatUrl: string, clientId: string, onScreen: boolean): void {
  useEffect(() => {
    if (!onScreen) return undefined;
    const store = repliesFor(clientId, chatUrl);
    store.chatAppeared();
    return () => store.chatWentAway();
  }, [chatUrl, clientId, onScreen]);
}

/**
 * The chat, presented over the host app. Render it once anywhere in the tree
 * and drive `visible` yourself, or let `useKeydaBot` hold that state for you.
 * To put the chat inside one of your own screens instead, see `KeydaBotChat`.
 */
export function KeydaBot({clientId, baseUrl, visible, onClose, question, questionKey, visitor}: KeydaBotProps): React.ReactElement {
  // Built on every render, not lazily on first show: a typo in the id then
  // throws while the developer is looking at the screen, instead of the first
  // time a customer taps the button.
  const chatUrl = useMemo(() => buildChatUrl(clientId, baseUrl), [clientId, baseUrl]);

  // The page owns the theme (the dashboard's Match the visitor / Always light /
  // Always dark is resolved there, not here — there is no theme prop), and it
  // tells this shell which scheme it settled on. Until that message arrives —
  // and against a backend that predates it — the device scheme stands in,
  // which is what "Match the visitor" means. Nothing here is a prop, so a host
  // app cannot override the owner's choice.
  const deviceScheme: Scheme = useColorScheme() === 'dark' ? 'dark' : 'light';
  const [pageScheme, setPageScheme] = useState<Scheme | null>(null);
  const colors = PALETTE[pageScheme ?? deviceScheme];

  const [status, setStatus] = useState<Status>('loading');
  const androidInsets = useAndroidInsets(visible);
  const edgeToEdge = androidInsets.edgeToEdge;
  const wasVisible = useRef(false);
  const webRef = useRef<WebHandle | null>(null);
  // The fallback for a back press the page has not answered yet.
  const pendingBack = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Retrying by remounting rather than by reload(): after an Android renderer
  // death the old WebView instance must not be touched again, and a fresh one
  // is the single retry that works in every failure mode. Nothing is lost — the
  // conversation id lives in the page's DOM storage.
  const [attempt, setAttempt] = useState(0);
  const delivered = useRef(false);
  const cleanVisitorValue = useMemo(() => cleanVisitor(visitor), [visitor?.name, visitor?.phone, visitor?.email]);
  const {startUrl, asked} = useStartUrl(chatUrl, question, questionKey, cleanVisitorValue, visible, attempt, delivered);
  // A page that loaded in THIS open. `status` alone cannot say: on the render
  // that opens the chat again it still reads 'ready' from the last open, and a
  // start marked delivered then was lost to a failed first load and a Retry.
  const ready = visible && status === 'ready' && delivered.current;
  usePrefill(question, questionKey, ready, asked, webRef);
  const pushVisitor = useVisitorUpdates(cleanVisitorValue, ready, webRef);
  useOnScreen(chatUrl, clientId, visible);
  const handleLoaded = useCallback(() => {
    delivered.current = true;
    pushVisitor();
  }, [pushVisitor]);

  useEffect(() => {
    if (visible) {
      wasVisible.current = true;
      return;
    }
    if (!wasVisible.current) return;
    wasVisible.current = false;
    // The <StatusBar> below unmounts with the chat, and React Native then
    // re-applies the app's default, 'default' — light icons on Android. For an
    // edge-to-edge app that never styled its bar, its real look was its
    // theme's (dark icons on a light app): left alone, the time and battery
    // went white on white the moment the chat closed. Put that look back.
    if (Platform.OS === 'android' && edgeToEdge && hostLeftStatusBarUnstyled()) {
      StatusBar.setBarStyle(deviceScheme === 'dark' ? 'light-content' : 'dark-content', false);
    }
  }, [visible, edgeToEdge, deviceScheme]);

  useEffect(() => {
    // Modal tears its children down when it hides, so a WebView that failed is
    // already gone; the flag it left behind must not greet the next open with a
    // retry screen for a load that never happened.
    if (visible) {
      setStatus('loading');
    } else {
      // The theme the page reported belongs to THAT page instance, and the
      // next open loads a fresh one: an owner who switched the bot to Always
      // light in between must not see a dark cover paint over a light chat.
      setPageScheme(null);
    }
  }, [visible]);

  useEffect(
    () => () => {
      if (pendingBack.current !== null) {
        clearTimeout(pendingBack.current);
        pendingBack.current = null;
      }
    },
    [visible],
  );

  const handleBack = useCallback(() => {
    // iOS calls onRequestClose only for a sheet the customer swiped away (it
    // is already gone): close, nothing to ask. And nothing the page drew can be
    // open before it has loaded, and a retry screen has no sheets: back leaves.
    const web = webRef.current;
    if (Platform.OS !== 'android' || !ready || web === null) {
      onClose();
      return;
    }
    // A second press while the page is answering the first: that answer decides.
    if (pendingBack.current !== null) {
      return;
    }
    pendingBack.current = setTimeout(() => {
      pendingBack.current = null;
      onClose();
    }, BACK_ANSWER_MS);
    web.injectJavaScript(BACK_SCRIPT);
  }, [ready, onClose]);

  const retry = useCallback(() => {
    setStatus('loading');
    setAttempt(a => a + 1);
  }, []);

  const handleMessage = useCallback(
    (data: unknown) => {
      // The event carries whatever the page passed to postMessage, verbatim.
      // setState from a WebView callback already lands on the JS thread.
      const scheme = themeFromMessage(data);
      if (scheme !== null) {
        setPageScheme(scheme);
        return;
      }
      const waits = waitsFromMessage(data);
      if (waits !== null) {
        repliesFor(clientId, chatUrl).onWaits(waits, visible);
        return;
      }
      // Only an answer to a back press this shell is waiting on counts; the
      // page cannot close the chat by posting one unasked.
      const handled = backAnswerFromMessage(data);
      if (handled === null || pendingBack.current === null) {
        return;
      }
      clearTimeout(pendingBack.current);
      pendingBack.current = null;
      if (!handled) {
        onClose();
      }
    },
    [onClose, clientId, chatUrl, visible],
  );

  // Read only on iOS: see the note on the container below.
  const Container = Platform.OS === 'ios' ? SafeAreaView : View;

  return (
    <Modal
      visible={visible}
      animationType="slide"
      // Android back. Without it the chat is a room with no door; it closes a
      // sheet the page has open first (handleBack).
      onRequestClose={handleBack}
      // iOS modals are portrait-only unless told otherwise, so an app that
      // rotates would freeze the chat in portrait.
      supportedOrientations={['portrait', 'landscape']}>
      {/* Bar text must contrast with the chat behind it, which follows the
          scheme. RN restores the previous style when this unmounts, so the host
          app's own bar is not disturbed. */}
      <StatusBar barStyle={colors.bar} />
      {/* Insets on every edge. The page ships viewport-fit=cover and pads only
          its footer and sides itself (none of it inside an Android shell,
          where WebViews report env() wrongly), so this container keeps the
          close bar and the chat out of the notch, the status bar and, on
          Android, the navigation bar.
          Core SafeAreaView is deprecated in favour of
          react-native-safe-area-context, but it is the ONLY dependency-free
          source of the notch / home-indicator insets on iOS (StatusBar.
          currentHeight is Android-only and says nothing about the bottom), and
          this package takes no dependency beyond the WebView peer. It stays
          until React Native removes it; see Limitations in the README.
          iOS only: on Android it is a plain View that pads nothing (the
          insets there are useAndroidInsets'), and reading it from
          'react-native' is what raises the deprecation warning — a toast
          that sat over the message box in every development build. */}
      <Container
        onLayout={androidInsets.onLayout}
        style={[
          styles.root,
          {
            backgroundColor: colors.bg,
            paddingTop: androidInsets.top,
            paddingBottom: androidInsets.bottom,
            paddingLeft: androidInsets.left,
            paddingRight: androidInsets.right,
          },
        ]}>
        <View style={styles.bar}>
          {/* The page renders its own header but NO close button when it is
              embedded like this — this is the only way out of the chat. */}
          <Pressable
            onPress={onClose}
            accessibilityRole="button"
            accessibilityLabel="Close chat"
            hitSlop={12}
            style={styles.close}>
            <Text style={[styles.closeGlyph, {color: colors.glyph}]} maxFontSizeMultiplier={1.6}>
              ✕
            </Text>
          </Pressable>
        </View>
        <KeyboardAvoidingView
          style={styles.fill}
          // iOS: WKWebView does not shrink the page for the keyboard, so the
          // chat's fixed-position input would sit underneath it. Shrinking this
          // view shrinks the page's viewport and lifts the input clear.
          // Android does it through the window (or useAndroidInsets when the
          // window is edge-to-edge); padding here as well would count it twice.
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ChatSurface
            chatUrl={chatUrl}
            startUrl={startUrl}
            colors={colors}
            status={status}
            setStatus={setStatus}
            attempt={attempt}
            onRetry={retry}
            webRef={webRef}
            onMessage={handleMessage}
            onLoaded={handleLoaded}
          />
        </KeyboardAvoidingView>
      </Container>
    </Modal>
  );
}

export interface KeydaBotChatProps {
  /** From Install in the Keyda Business dashboard: kb_live_ + 8-48 hex chars. */
  clientId: string;
  /** Override for self-hosting or staging. Defaults to https://keyda.in/business */
  baseUrl?: string;
  /** Optional: as on `<KeydaBot />`. */
  question?: string;
  /** Optional: your signed-in customer, as on `<KeydaBot />`. */
  visitor?: KeydaBotVisitor;
  /**
   * Is this screen the one in front? Pass React Navigation's `useIsFocused()`
   * (or your tab's selected state) when the chat sits in a tab or under other
   * screens that stay mounted. While false, Android's back is left to your app
   * — it would otherwise close a sheet in a chat nobody can see — and the chat
   * counts as off screen, so the SDK checks for the business's replies itself
   * (`useKeydaBotReplies`). Default true.
   */
  focused?: boolean;
  /** Size and place it like any view; it fills what it is given. */
  style?: StyleProp<ViewStyle>;
  /**
   * Called with true when the chat opens a sheet over the conversation (an
   * item, the cart, a booking) and false when the last one closes. Android's
   * back closes that sheet first by itself; this is for a host that wants to
   * know, e.g. to keep a navigator's own back from firing.
   */
  onCanGoBackChange?: (canGoBack: boolean) => void;
}

/**
 * The chat as a view of your own screen — a Help tab, a support screen —
 * rather than the full-screen `<KeydaBot />`. Same hosted page, same rules.
 *
 * It has no close button (your screen's navigation is the way out) and pads
 * for nothing but the keyboard: lay it out clear of the status and navigation
 * bars as you would any view. On Android, back closes a sheet the chat has
 * open (an item, the cart) before your app's own back handling sees it.
 */
export function KeydaBotChat({clientId, baseUrl, question, visitor, focused = true, style, onCanGoBackChange}: KeydaBotChatProps): React.ReactElement {
  const chatUrl = useMemo(() => buildChatUrl(clientId, baseUrl), [clientId, baseUrl]);
  const deviceScheme: Scheme = useColorScheme() === 'dark' ? 'dark' : 'light';
  const [pageScheme, setPageScheme] = useState<Scheme | null>(null);
  const colors = PALETTE[pageScheme ?? deviceScheme];
  const [status, setStatus] = useState<Status>('loading');
  const [attempt, setAttempt] = useState(0);
  const [sheets, setSheets] = useState(0);
  const webRef = useRef<WebHandle | null>(null);
  const delivered = useRef(false);
  const cleanVisitorValue = useMemo(() => cleanVisitor(visitor), [visitor?.name, visitor?.phone, visitor?.email]);
  const {startUrl, asked} = useStartUrl(chatUrl, question, undefined, cleanVisitorValue, true, attempt, delivered);
  usePrefill(question, undefined, status === 'ready', asked, webRef);
  const pushVisitor = useVisitorUpdates(cleanVisitorValue, status === 'ready', webRef);
  useOnScreen(chatUrl, clientId, focused);
  const handleLoaded = useCallback(() => {
    delivered.current = true;
    pushVisitor();
  }, [pushVisitor]);

  const canGoBack = sheets > 0 && status === 'ready';
  const reported = useRef(false);
  useEffect(() => {
    if (!onCanGoBackChange) return;
    if (!reported.current && !canGoBack) return;
    reported.current = true;
    onCanGoBackChange(canGoBack);
  }, [canGoBack, onCanGoBackChange]);

  useEffect(() => {
    // Android back answers at once — the sheet count is known — so it can take
    // the press only when there is a sheet to close and leave it to the app's
    // own navigation otherwise. Registered last, so it is asked first. Never
    // from a chat that is not in front: BackHandler is global.
    if (Platform.OS !== 'android' || !canGoBack || !focused) return undefined;
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (webRef.current) webRef.current.injectJavaScript(BACK_ONLY_SCRIPT);
      return true;
    });
    return () => sub.remove();
  }, [canGoBack, focused]);

  const retry = useCallback(() => {
    setStatus('loading');
    setSheets(0);
    setAttempt(a => a + 1);
  }, []);

  const handleMessage = useCallback((data: unknown) => {
    const scheme = themeFromMessage(data);
    if (scheme !== null) {
      setPageScheme(scheme);
      return;
    }
    const waits = waitsFromMessage(data);
    if (waits !== null) {
      // A chat in a tab that is not selected draws a reply nobody sees.
      repliesFor(clientId, chatUrl).onWaits(waits, focused);
      return;
    }
    const open = sheetsFromMessage(data);
    if (open !== null) setSheets(open);
  }, [clientId, chatUrl, focused]);

  // The keyboard. React Native's KeyboardAvoidingView measures itself against
  // its PARENT, which is only right for a view at the top of the screen; a
  // chat under a header got the overlap wrong. Measured in the window instead:
  // a window that resizes for the keyboard moves the view out of its way and
  // the overlap comes out 0, so nothing is counted twice.
  // Typed by the one method used, and spread in: React Native types a View's
  // ref differently from one release to the next.
  const box = useRef<{measureInWindow: (cb: (x: number, y: number, w: number, h: number) => void) => void} | null>(null);
  const boxRefProp = useMemo(() => ({ref: box}) as {}, []);
  const keyboardTop = useRef<number | null>(null);
  const [overlap, setOverlap] = useState(0);
  const measure = useCallback(() => {
    const top = keyboardTop.current;
    if (top === null || !box.current) {
      setOverlap(0);
      return;
    }
    box.current.measureInWindow((_x: number, y: number, _w: number, h: number) => {
      setOverlap(Math.max(0, Math.round(y + h - top)));
    });
  }, []);
  useEffect(() => {
    const show = Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow';
    const hide = Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide';
    const a = Keyboard.addListener(show, e => {
      keyboardTop.current = e.endCoordinates.screenY;
      measure();
    });
    const b = Keyboard.addListener(hide, () => {
      keyboardTop.current = null;
      setOverlap(0);
    });
    return () => {
      a.remove();
      b.remove();
    };
  }, [measure]);

  return (
    <View {...boxRefProp} onLayout={measure} style={[styles.root, {backgroundColor: colors.bg}, style]}>
      <View style={[styles.fill, {paddingBottom: overlap}]}>
        <ChatSurface
          chatUrl={chatUrl}
          startUrl={startUrl}
          colors={colors}
          status={status}
          setStatus={setStatus}
          attempt={attempt}
          onRetry={retry}
          webRef={webRef}
          onMessage={handleMessage}
          onLoaded={handleLoaded}
        />
      </View>
    </View>
  );
}

export interface KeydaBotController {
  /** Is the chat presented right now. */
  isShowing: boolean;
  /**
   * Present the chat, optionally with a question in its message box (unsent).
   * Called while it is showing, the question replaces what is in the box.
   */
  show: (question?: string) => void;
  /** Close it. */
  dismiss: () => void;
  /** Spread onto <KeydaBot />. */
  botProps: KeydaBotProps;
}

/**
 * Holds the show/dismiss state so a screen does not have to. The whole public
 * surface — init, show, dismiss, isShowing — and nothing beyond it.
 */
export function useKeydaBot(clientId: string, baseUrl?: string): KeydaBotController {
  // Validate at init, not at first show: a bot behind a support button would
  // otherwise hide a bad client id until someone actually tapped it.
  useMemo(() => buildChatUrl(clientId, baseUrl), [clientId, baseUrl]);

  const [isShowing, setShowing] = useState(false);
  const [question, setQuestion] = useState<string | undefined>(undefined);
  const [questionKey, setQuestionKey] = useState(0);
  const show = useCallback((q?: string) => {
    // `onPress={bot.show}` hands it the press event; only a string is a question.
    setQuestion(typeof q === 'string' ? q : undefined);
    setQuestionKey(k => k + 1);
    setShowing(true);
  }, []);
  const dismiss = useCallback(() => setShowing(false), []);
  const botProps = useMemo<KeydaBotProps>(
    () => ({clientId, baseUrl, visible: isShowing, onClose: dismiss, question, questionKey}),
    [clientId, baseUrl, isShowing, dismiss, question, questionKey],
  );

  return {isShowing, show, dismiss, botProps};
}

/**
 * A reply from the business that came while no chat was on screen.
 *
 * A customer who asked for a person closes the chat; the owner answers an hour
 * later. The chat shows the answer when it next opens — this tells your app it
 * is there, so you can put a dot on your chat button. `hasUnreadReply` stays
 * true until the chat is on screen — a `<KeydaBotChat focused={false}>` draws
 * the reply out of sight, which does not count; `onReply` is called once per
 * new reply. The SDK asks when your app comes to the foreground (once a minute
 * at most), only for chats in which the customer asked for a person in the
 * last 14 days.
 *
 * Pass `storage` (AsyncStorage, or anything with its getItem/setItem) to keep
 * watching across app restarts; without it, only while the app runs.
 */
export function useKeydaBotReplies(clientId: string, options: KeydaBotRepliesOptions = {}): KeydaBotReplies {
  const chatUrl = useMemo(() => buildChatUrl(clientId, options.baseUrl), [clientId, options.baseUrl]);
  const store = useMemo(() => repliesFor(clientId, chatUrl), [clientId, chatUrl]);
  return useReplyStore(store, options);
}

// Every surface colour is applied inline from PALETTE so the container and the
// page inside it are one surface rather than two, in both schemes; only the
// scheme-independent geometry lives here.
const styles = StyleSheet.create({
  root: {flex: 1},
  fill: {flex: 1},
  bar: {
    height: 44,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    paddingHorizontal: 8,
  },
  close: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
  },
  closeGlyph: {fontSize: 18, lineHeight: 22},
  web: {flex: 1},
  // Written out rather than StyleSheet.absoluteFillObject, which React Native
  // 0.87 removed: spread from undefined, the cover lost its position and sat
  // as a strip under a white first frame instead of covering it.
  cover: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  center: {flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24},
  errorTitle: {fontSize: 17, fontWeight: '600', marginBottom: 6},
  errorBody: {fontSize: 15, textAlign: 'center', marginBottom: 18},
  retry: {
    paddingHorizontal: 20,
    paddingVertical: 11,
    borderRadius: 10,
    backgroundColor: '#3b4ee0',
  },
  retryLabel: {color: '#ffffff', fontSize: 15, fontWeight: '600'},
});
