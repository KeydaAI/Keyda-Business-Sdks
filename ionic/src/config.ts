/**
 * The client id rule and the URL shape, in one place.
 *
 * Both surfaces in this package build URLs from a client id — the full-screen
 * one opens `/chat/{clientId}`, the embedded one puts the id on a script tag.
 * If they validated separately the two would drift, and the symptom would be
 * an id that opens fine full-screen and silently fails to embed.
 */

/** Where the hosted chat page and `widget.js` are served from. */
export const DEFAULT_BASE_URL = 'https://keyda.in/business';

/**
 * `kb_live_` followed by 8-48 hex characters, per CONTRACT.md.
 *
 * Anchored at both ends because the realistic failure is a copy-paste that
 * brought a trailing newline or a stray quote with it. An unanchored test
 * accepts that, and the id then goes into a URL that 404s — in front of a
 * customer, on a screen nobody on the team is looking at.
 */
const CLIENT_ID_PATTERN = /^kb_live_[0-9a-f]{8,48}$/;

/**
 * Returns the id, or throws.
 *
 * Throwing is deliberate here and nowhere else in this package. A malformed
 * client id is a mistake in the integrator's own source: it fails identically
 * on every run, so it surfaces on the first launch in development and can
 * never reach a customer. A failed page load is the opposite — a runtime
 * condition on someone's train commute — and must never throw. See `open()`
 * and `embedWidget()`, which both report failure by return value.
 */
export function assertClientId(clientId: string): string {
  if (typeof clientId !== 'string' || !CLIENT_ID_PATTERN.test(clientId)) {
    throw new Error(
      `[KeydaBot] "${String(clientId)}" is not a Keyda client id. Expected ` +
        `kb_live_ followed by 8-48 hex characters. Copy it from Install in ` +
        `the Keyda Business dashboard: https://keyda.in/business/app/`,
    );
  }
  return clientId;
}

/**
 * Trims a trailing slash so callers can pass either form, and refuses
 * anything that is not http(s).
 *
 * The scheme check is not pedantry: `baseUrl` is the one value here that
 * tends to arrive from an environment variable or a remote config, and
 * without the check a `javascript:` string would be handed straight to
 * `window.open` inside the host app.
 */
export function normaliseBaseUrl(baseUrl?: string): string {
  const raw = (baseUrl ?? '').trim();
  if (!raw) return DEFAULT_BASE_URL;

  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(
      `[KeydaBot] baseUrl "${raw}" is not an absolute URL. Pass something ` +
        `like "https://keyda.in/business", or omit it to use the default.`,
    );
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new Error(`[KeydaBot] baseUrl "${raw}" must be http or https.`);
  }
  // Keep the path: a self-host may sit under a prefix such as
  // https://example.in/keyda, and dropping it would 404 every request.
  return raw.replace(/\/+$/, '');
}

/** The hosted chat page for a bot — the single URL every Keyda SDK opens. */
export function chatUrl(clientId: string, baseUrl?: string): string {
  return `${normaliseBaseUrl(baseUrl)}/chat/${assertClientId(clientId)}`;
}

/** The embeddable widget script for a deployment. */
export function widgetScriptUrl(baseUrl?: string): string {
  return `${normaliseBaseUrl(baseUrl)}/widget.js`;
}

/** Console-only. Nothing in this package reports a runtime problem by throwing. */
export function warn(message: string, detail?: unknown): void {
  if (typeof console === 'undefined' || !console.warn) return;
  if (detail === undefined) console.warn(`[KeydaBot] ${message}`);
  else console.warn(`[KeydaBot] ${message}`, detail);
}
