/**
 * The `visitor` prop's rules — the chat page's own, and every Keyda SDK's — so
 * a value the page would drop never leaves the app.
 *
 * A value that does not look like what it claims is dropped whole, never cut:
 * a phone number or an email with its end cut off is a wrong one, offered to
 * the customer as if it were theirs.
 */

/**
 * Your signed-in customer, so the chat does not ask what your app already
 * knows. Offered — never sent — in the forms that ask for them ("talk to a
 * person", an order, a booking, a welcome question for a name, phone or
 * email); the customer sees them and submits. They travel in the URL's
 * #fragment, which no server sees, and are your app's word, not a verified
 * identity. Each is optional; one that does not look like what it claims is
 * dropped: a name of 1–80 characters on one line, a phone number with 8–15
 * digits (and only `+ - ( ) .` and spaces besides), an email up to 254
 * characters. Pass `undefined` when the customer signs out.
 */
export interface KeydaBotVisitor {
  name?: string;
  phone?: string;
  email?: string;
}

const NAME_MAX = 80;
const PHONE = /^\+?[0-9() .-]{8,32}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$/;

/** Half of a UTF-16 pair with no other half: encodeURIComponent throws on one. */
export function isLoneSurrogate(c: string): boolean {
  if (c.length !== 1) return false;
  const n = c.charCodeAt(0);
  return n >= 0xd800 && n <= 0xdfff;
}

/**
 * One line of 1–80 characters, or ''. Control characters become a space and
 * runs of spaces one; nothing else is taken out — a zero-width joiner, a soft
 * hyphen or a direction mark is part of how some names are written.
 */
export function cleanName(value: unknown): string {
  if (typeof value !== 'string') return '';
  const name = Array.from(value)
    .filter(c => !isLoneSurrogate(c))
    .join('')
    .replace(/[\x00-\x1f\x7f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const length = Array.from(name).length;
  return length >= 1 && length <= NAME_MAX ? name : '';
}

/**
 * 8–15 digits — the shortest national numbers to the longest international
 * one — with spaces and `+ - ( ) .` between them, or ''. No country code
 * starts with 0, so "+0…" is not a number anyone has.
 */
export function cleanPhone(value: unknown): string {
  if (typeof value !== 'string') return '';
  const phone = value.trim();
  const digits = phone.replace(/\D/g, '').length;
  return PHONE.test(phone) && digits >= 8 && digits <= 15 && !phone.startsWith('+0') ? phone : '';
}

/** Something@somewhere.tld, up to 254 characters and with no "..", or ''. */
export function cleanEmail(value: unknown): string {
  if (typeof value !== 'string') return '';
  const email = value.trim();
  return email.length <= 254 && EMAIL.test(email) && email.indexOf('..') < 0 ? email : '';
}

/** What is left of a visitor, or null when nothing is — the same as no visitor. */
export function cleanVisitor(visitor: KeydaBotVisitor | null | undefined): Required<KeydaBotVisitor> | null {
  if (!visitor || typeof visitor !== 'object') return null;
  const out = {name: cleanName(visitor.name), phone: cleanPhone(visitor.phone), email: cleanEmail(visitor.email)};
  return out.name || out.phone || out.email ? out : null;
}
