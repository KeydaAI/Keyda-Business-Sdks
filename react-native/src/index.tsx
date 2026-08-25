/**
 * @keyda/bot-react-native
 *
 * A Modal + WebView around the hosted chat page at {baseUrl}/chat/{clientId}.
 * There is one chat renderer — the web widget the platform serves — and every
 * Keyda SDK loads it, so an owner's dashboard change (welcome message, accent,
 * knowledge) reaches this app with no app release. See CONTRACT.md in the repo.
 */
import React, {useCallback, useEffect, useMemo, useState} from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Linking,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {WebView} from 'react-native-webview';

const DEFAULT_BASE_URL = 'https://keyda.in/business';

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
}

type Status = 'loading' | 'ready' | 'failed';

/**
 * The chat, presented over the host app. Render it once anywhere in the tree
 * and drive `visible` yourself, or let `useKeydaBot` hold that state for you.
 */
export function KeydaBot({clientId, baseUrl, visible, onClose}: KeydaBotProps): React.ReactElement {
  // Built on every render, not lazily on first show: a typo in the id then
  // throws while the developer is looking at the screen, instead of the first
  // time a customer taps the button.
  const chatUrl = useMemo(() => buildChatUrl(clientId, baseUrl), [clientId, baseUrl]);

  const [status, setStatus] = useState<Status>('loading');
  // Retrying by remounting rather than by reload(): after an Android renderer
  // death the old WebView instance must not be touched again, and a fresh one
  // is the single retry that works in every failure mode. Nothing is lost — the
  // conversation id lives in the page's DOM storage.
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    // Modal tears its children down when it hides, so a WebView that failed is
    // already gone; the flag it left behind must not greet the next open with a
    // retry screen for a load that never happened.
    if (visible) {
      setStatus('loading');
    }
  }, [visible]);

  const retry = useCallback(() => {
    setStatus('loading');
    setAttempt(a => a + 1);
  }, []);

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

  const handleLoadEnd = useCallback(() => {
    // onLoadEnd fires for a failed load too, and can arrive after onError — so
    // a load that already reported an error must not be marked ready, or the
    // retry screen never appears.
    setStatus(s => (s === 'failed' ? s : 'ready'));
  }, []);

  const handleError = useCallback(() => setStatus('failed'), []);

  const handleHttpError = useCallback(
    (event: {nativeEvent: {url?: string}}) => {
      // onHttpError also fires for sub-resources on iOS. A 404 on some image
      // must not replace a chat that is working; only the chat document counts.
      const url = event.nativeEvent && event.nativeEvent.url;
      if (typeof url === 'string' && staysInChat(url, chatUrl)) {
        setStatus('failed');
      }
    },
    [chatUrl],
  );

  const handleProcessGone = useCallback(() => {
    // Android kills WebView renderers under memory pressure, and using that
    // WebView again takes the host app down with it. Handling the event at all
    // is what keeps the crash from happening; the retry screen mounts a new one.
    setStatus('failed');
  }, []);

  return (
    <Modal
      visible={visible}
      animationType="slide"
      // Android hardware back. Without it the chat is a room with no door.
      onRequestClose={onClose}
      // iOS modals are portrait-only unless told otherwise, so an app that
      // rotates would freeze the chat in portrait.
      supportedOrientations={['portrait', 'landscape']}>
      {/* The chat page is light; a host app in dark mode leaves white status
          bar text unreadable over it. RN restores the previous style when this
          unmounts, so the host app's own bar is not disturbed. */}
      <StatusBar barStyle="dark-content" />
      {/* Insets on every edge: the page ships viewport-fit=cover but sets no
          env(safe-area-inset-*) padding of its own, so nothing else keeps the
          message box off the home indicator or out of the notch. */}
      <SafeAreaView style={styles.root}>
        <View style={styles.bar}>
          {/* The page renders its own header but NO close button when it is
              embedded like this — this is the only way out of the chat. */}
          <Pressable
            onPress={onClose}
            accessibilityRole="button"
            accessibilityLabel="Close chat"
            hitSlop={12}
            style={styles.close}>
            <Text style={styles.closeGlyph} maxFontSizeMultiplier={1.6}>
              ✕
            </Text>
          </Pressable>
        </View>
        <KeyboardAvoidingView
          style={styles.fill}
          // iOS: WKWebView does not shrink the page for the keyboard, so the
          // chat's fixed-position input would sit underneath it. Shrinking this
          // view shrinks the page's viewport and lifts the input clear.
          // Android does it through the window (see adjustResize in the README);
          // adding padding as well would double-count the keyboard.
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          {status === 'failed' ? (
            <View style={styles.center}>
              <Text style={styles.errorTitle}>Chat didn’t load</Text>
              <Text style={styles.errorBody}>Check your connection and try again.</Text>
              <Pressable onPress={retry} accessibilityRole="button" style={styles.retry}>
                <Text style={styles.retryLabel}>Try again</Text>
              </Pressable>
            </View>
          ) : (
            <>
              <WebView
                key={attempt}
                source={{uri: chatUrl}}
                style={styles.web}
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
                // iOS: KeyboardAvoidingView above already resizes this view for
                // the keyboard; WKWebView's own inset on top of that leaves a
                // gap the height of the keyboard.
                automaticallyAdjustContentInsets={false}
                contentInsetAdjustmentBehavior="never"
                // The page is a fixed full-screen layout — Android's overscroll
                // glow on it just reads as broken.
                overScrollMode="never"
                onLoadEnd={handleLoadEnd}
                onError={handleError}
                onHttpError={handleHttpError}
                onRenderProcessGone={handleProcessGone}
                onContentProcessDidTerminate={handleProcessGone}
              />
              {status === 'loading' ? (
                // Covers the WebView's white first frame with the page's own
                // background, so opening the chat is not a flash of white.
                <View style={styles.cover} pointerEvents="none">
                  <ActivityIndicator />
                </View>
              ) : null}
            </>
          )}
        </KeyboardAvoidingView>
      </SafeAreaView>
    </Modal>
  );
}

export interface KeydaBotController {
  /** Is the chat presented right now. */
  isShowing: boolean;
  /** Present the chat. */
  show: () => void;
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
  const show = useCallback(() => setShowing(true), []);
  const dismiss = useCallback(() => setShowing(false), []);
  const botProps = useMemo<KeydaBotProps>(
    () => ({clientId, baseUrl, visible: isShowing, onClose: dismiss}),
    [clientId, baseUrl, isShowing, dismiss],
  );

  return {isShowing, show, dismiss, botProps};
}

// #f7f8fc is the chat page's own background, so the container it sits in and
// the page itself are one surface rather than two.
const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#f7f8fc'},
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
  closeGlyph: {fontSize: 18, lineHeight: 22, color: '#4a5570'},
  web: {flex: 1, backgroundColor: '#f7f8fc'},
  cover: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: '#f7f8fc',
    alignItems: 'center',
    justifyContent: 'center',
  },
  center: {flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24},
  errorTitle: {fontSize: 17, fontWeight: '600', color: '#1f2740', marginBottom: 6},
  errorBody: {fontSize: 15, color: '#4a5570', textAlign: 'center', marginBottom: 18},
  retry: {
    paddingHorizontal: 20,
    paddingVertical: 11,
    borderRadius: 10,
    backgroundColor: '#3b4ee0',
  },
  retryLabel: {color: '#ffffff', fontSize: 15, fontWeight: '600'},
});
