/**
 * The embedded surface: the same `widget.js` script tag a Keyda customer
 * pastes into a website, injected into the Capacitor WebView's document.
 *
 * An Ionic or Capacitor app already IS a web view, so the plain script tag
 * works there unchanged, and for most apps it is the better answer — a
 * floating launcher over your own UI, no plugin, no navigation away from your
 * screens. This helper exists only so you do not have to hand-write the tag,
 * guess the injection point, or handle the double-embed case yourself.
 */
import { assertClientId, warn, widgetScriptUrl } from './config.js';

export interface EmbedOptions {
  /** From Install in the Keyda Business dashboard: `kb_live_…`. */
  clientId: string;
  /** Defaults to `https://keyda.in/business`. Set it for staging or a self-host. */
  baseUrl?: string;
}

/**
 * The controls `widget.js` publishes once it is running in the page.
 *
 * This is the widget's own API, not this package's — see `getEmbeddedWidget()`
 * for the one caveat that matters.
 */
export interface EmbeddedWidget {
  /** Opens the chat panel. */
  open(): void;
  /** Closes the panel, leaving the floating launcher. */
  close(): void;
  toggle(): void;
  readonly isOpen: boolean;
}

/**
 * Our own attribute, so `embedWidget()` can recognise the tag it added.
 *
 * Matching on `src` instead would also match a tag the developer pasted into
 * `index.html` by hand — which is a case we WANT to detect, and do, via the
 * `window.KeydaBot` check below. Two different questions, two different tests.
 */
const SCRIPT_MARKER = 'data-keyda-embed';

/**
 * Injects `<script src="{baseUrl}/widget.js" data-key="{clientId}" async>`.
 *
 * Resolves `true` when the script has loaded and executed. That is not the
 * same as "the chat bubble is visible": the widget then fetches its own
 * config over the network, and can still decline to mount (a bot that is not
 * live, or an authorised-domains list that does not include this app's
 * origin). Failures after this point are reported in the console by the
 * widget, which never renders a broken bubble on someone's page.
 *
 * Resolves `false` instead of rejecting when the script cannot be fetched —
 * offline, blocked, wrong `baseUrl`. Nothing about a chat widget justifies
 * taking the host app down with it.
 *
 * Throws only for a malformed `clientId`, which is a source-code error that
 * fails on the very first run. See `assertClientId`.
 */
export function embedWidget(options: EmbedOptions): Promise<boolean> {
  const clientId = assertClientId(options.clientId);
  const src = widgetScriptUrl(options.baseUrl);

  if (typeof document === 'undefined') {
    // Angular Universal and every other prerender step run this module with
    // no DOM. Failing the whole server render over a chat bubble would be a
    // poor trade, so this is a no-op there and the widget appears when the
    // page hydrates in the browser.
    warn('no document available — skipping the embed (server-side rendering?)');
    return Promise.resolve(false);
  }

  // Two ways the widget can already be present: we added the tag before, or
  // it is running. widget.js has its own double-embed guard, so a second tag
  // would be harmless but pointless — and a second network request.
  if (document.querySelector(`script[${SCRIPT_MARKER}]`) || getEmbeddedWidget()) {
    return Promise.resolve(true);
  }

  return new Promise<boolean>((resolve) => {
    const script = document.createElement('script');
    script.src = src;
    script.async = true;
    script.setAttribute('data-key', clientId);
    script.setAttribute(SCRIPT_MARKER, '');

    script.addEventListener('load', () => resolve(true), { once: true });
    script.addEventListener(
      'error',
      () => {
        // Remove the tag on the way out. Left in place it would satisfy the
        // idempotency check above and turn away every later retry, so one
        // failed load would mean no chat until the app restarts.
        script.remove();
        warn(`could not load ${src} — chat is unavailable until it does.`);
        resolve(false);
      },
      { once: true },
    );

    (document.head || document.documentElement).appendChild(script);
  });
}

/**
 * The running widget's controls, or `null` if it is not in the page yet.
 *
 * Use it to open the chat from your own button instead of the floating
 * launcher.
 *
 * Two things to know. First, the object lives at `window.KeydaBot`, which is
 * NOT this package's exported `KeydaBot` — that one drives the full-screen
 * surface and the two share no state. Second, this can return non-null in the
 * gap between the script executing and the widget finishing its config fetch;
 * calling `open()` in that gap does nothing at all rather than erroring. If
 * you are wiring a button, the gap is over long before anyone can press it.
 */
export function getEmbeddedWidget(): EmbeddedWidget | null {
  if (typeof window === 'undefined') return null;
  const widget = (window as unknown as { KeydaBot?: EmbeddedWidget & { __loaded?: boolean } })
    .KeydaBot;
  // `__loaded` is widget.js's own marker. Testing it, rather than testing for
  // the object, avoids mistaking some other `window.KeydaBot` for the widget.
  return widget && widget.__loaded ? widget : null;
}
