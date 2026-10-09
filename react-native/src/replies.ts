/**
 * A reply from the business that arrives while the chat is closed.
 *
 * A customer who asked for a person leaves their details and closes the chat;
 * the owner answers in the dashboard an hour later. The answer lands in the
 * conversation, and the chat page shows it the next time it opens — but
 * nothing told the customer to open it. This is that something.
 *
 * The page is the source of truth. It keeps the chats it is waiting on (up to
 * three, for 14 days, each with the time of the last row it showed) and sends
 * that list over the bridge as `keyda:waits` whenever it changes. A store here
 * keeps a copy, and when the app comes to the foreground with no chat on
 * screen it asks the same public route the page asks
 * (`/widget/{clientId}/messages`) whether a person has written since. Nothing
 * here moves the page's place: the page does that when it draws the reply,
 * and sends the list back. Only a chat on screen counts as the customer having
 * seen it — one loaded out of sight draws the reply all the same.
 *
 * Core React Native has no storage, and this package adds no dependency
 * (CONTRACT rule 5), so the copy lives in memory unless the app hands over a
 * `storage` — AsyncStorage, or anything with the same two methods.
 */
import {useCallback, useEffect, useRef, useState} from 'react';
import {AppState} from 'react-native';
import type {AppStateStatus} from 'react-native';

/** AsyncStorage's shape — pass `AsyncStorage` itself, or a wrapper round MMKV. */
export interface KeydaBotStorage {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem?(key: string): Promise<void>;
}

/**
 * One chat waiting for a reply.
 * - `at`: the customer's place — where the page was the last time a chat was
 *   on screen. The look asks for rows after it.
 * - `page`: where the page last said it was. A chat that is loaded but not on
 *   screen (a tab not selected) keeps polling and draws the reply where nobody
 *   sees it, so its place is not the customer's.
 * - `told`: the newest reply the customer has been told about.
 */
type Wait = {c: string; at: string; page: string; t: number; told: string};

const MAX_WAITS = 3;
const WAIT_TTL_MS = 14 * 24 * 60 * 60 * 1000;
/** One look per minute at most. Three requests a foreground is nothing; three a second is. */
const MIN_INTERVAL_MS = 60_000;
/** What `checkForReplies()` still waits between looks, for a host that calls it a lot. */
const MIN_FORCED_INTERVAL_MS = 10_000;
const TIMEOUT_MS = 10_000;
const CONVERSATION = /^[0-9a-f-]{36}$/i;
/** The server's ISO time, as the page stores it. Compared as strings, as the page does. */
const TIME = /^[0-9T:.+\-Z]{0,40}$/;

const later = (a: string, b: string): string => (a > b ? a : b);
const earlier = (a: string, b: string): string => (a < b ? a : b);

/** One entry of the page's list: well formed and under 14 days old, or null. */
function parseWait(item: unknown, now: number): {c: string; at: string; t: number} | null {
  if (!item || typeof item !== 'object') return null;
  const {c, at, t} = item as Record<string, unknown>;
  if (typeof c !== 'string' || !CONVERSATION.test(c)) return null;
  if (typeof at !== 'string' || !TIME.test(at)) return null;
  if (typeof t !== 'number' || t <= 0 || now - t >= WAIT_TTL_MS) return null;
  return {c, at, t};
}

/** The page's list, as it sends it: up to three. */
function parseWaits(list: unknown, now: number): {c: string; at: string; t: number}[] {
  if (!Array.isArray(list)) return [];
  const out: {c: string; at: string; t: number}[] = [];
  for (const item of list.slice(0, MAX_WAITS)) {
    const w = parseWait(item, now);
    if (w) out.push(w);
  }
  return out;
}

/** The list as this store saved it. One saved before `page` existed is at its own place. */
function loadWaits(list: unknown, now: number): Wait[] {
  if (!Array.isArray(list)) return [];
  const out: Wait[] = [];
  for (const item of list.slice(0, MAX_WAITS)) {
    const w = parseWait(item, now);
    if (!w) continue;
    const {page, told} = item as Record<string, unknown>;
    const p = typeof page === 'string' && TIME.test(page) ? later(page, w.at) : w.at;
    out.push({...w, page: p, told: typeof told === 'string' && TIME.test(told) ? later(told, p) : p});
  }
  return out;
}

class ReplyStore {
  private waits: Wait[] = [];
  private onScreen = 0;
  private lastLook = 0;
  private storage: KeydaBotStorage | null = null;
  private queue: Promise<void> = Promise.resolve();
  /** The page has sent its list since this store was made: memory is newer than disk. */
  private heard = false;
  unread = false;
  readonly changed = new Set<() => void>();
  readonly replied = new Set<() => void>();

  constructor(private readonly key: string, private readonly root: string, private readonly messagesUrl: string) {}

  /**
   * Every change to the list runs after the one before it: a page update that
   * lands while a look is waiting on the network must not be undone by it.
   */
  private run(work: () => Promise<void> | void): Promise<void> {
    this.queue = this.queue.then(work).catch(() => {});
    return this.queue;
  }

  useStorage(storage: KeydaBotStorage | undefined): void {
    if (!storage || storage === this.storage) return;
    this.storage = storage;
    this.run(async () => {
      let raw: string | null = null;
      try {
        raw = await storage.getItem(this.key);
      } catch {
        return;
      }
      let parsed: {root?: unknown; waits?: unknown} | null = null;
      try {
        parsed = raw ? JSON.parse(raw) : null;
      } catch {
        parsed = null;
      }
      const stored = parsed && parsed.root === this.root ? loadWaits(parsed.waits, Date.now()) : [];
      if (!this.heard) {
        this.waits = stored;
        return this.settle(false);
      }
      // The page spoke before the storage arrived, so its list is newer than
      // disk — but disk still knows which replies the customer was told about,
      // and they must not be told twice. Written back either way: left as it
      // was, disk would bring an old unread reply back at the next cold start.
      const told = new Map(stored.map((w) => [w.c, w.told] as const));
      for (const w of this.waits) w.told = later(w.told, told.get(w.c) ?? '');
      return this.settle(true);
    });
  }

  /**
   * A `keyda:waits` message from the page. `fromOnScreen`: the chat that sent
   * it counts as on screen. Only such a chat moves the customer's place. One
   * loaded out of sight (a tab not selected) keeps polling and draws what
   * comes where nobody sees it; taking its word made the badge go out on a
   * reply never seen.
   *
   * Nor is its word that a person wrote: the page moves its place for any
   * row — an order's status, the bot. When it moves on, this asks the route
   * at once instead, which counts only a person's rows, so a reply turns on
   * the badge and calls onReply, and anything else changes nothing.
   */
  onWaits(list: unknown, fromOnScreen: boolean): void {
    const parsed = parseWaits(list, Date.now());
    this.run(async () => {
      this.heard = true;
      const prior = new Map(this.waits.map((w) => [w.c, w] as const));
      let moved = false;
      this.waits = parsed.map(({c, at: page, t}) => {
        const p = prior.get(c);
        // What the customer was already told about survives the page's update.
        if (fromOnScreen) return {c, at: page, page, t, told: later(p ? p.told : '', page)};
        if (p && page > p.page) moved = true;
        const at = p ? earlier(p.at, page) : page;
        return {c, at, page, t, told: later(p ? p.told : '', at)};
      });
      await this.settle(true);
      // Not held to once a minute: the page's own poll, every 12 seconds, is
      // what bounds it.
      if (moved) await this.lookNow(0);
    });
  }

  /**
   * A chat came on screen: whatever is waiting is about to be shown there, and
   * whatever a chat out of sight drew is in front of the customer now. Unread
   * goes off at once — not behind a look that may be waiting on the network.
   */
  chatAppeared(): void {
    this.onScreen++;
    this.setUnread(false);
    this.run(() => {
      for (const w of this.waits) w.at = later(w.at, w.page);
      return this.settle(true);
    });
  }

  /**
   * Unread again only if the chat did not get to show the reply (it failed to
   * load, say): the page moves its place when it draws one, and sends the list
   * back first.
   */
  chatWentAway(): void {
    if (this.onScreen > 0) this.onScreen--;
    this.run(() => this.settle(false));
  }

  look(forced: boolean): Promise<void> {
    if (this.onScreen > 0) return Promise.resolve();
    return this.run(() => this.lookNow(forced ? MIN_FORCED_INTERVAL_MS : MIN_INTERVAL_MS));
  }

  private setUnread(value: boolean): void {
    if (this.unread === value) return;
    this.unread = value;
    for (const f of Array.from(this.changed)) f();
  }

  /** Unread: a person wrote past the customer's place, and no chat is on screen to show it. */
  private async settle(save: boolean): Promise<void> {
    this.setUnread(this.onScreen === 0 && this.waits.some((w) => w.told > w.at));
    if (save) await this.save();
  }

  /** Asks the route, unless the last look was under `limit` ms ago. */
  private async lookNow(limit: number): Promise<void> {
    const now = Date.now();
    const before = this.waits.length;
    this.waits = this.waits.filter((w) => now - w.t < WAIT_TTL_MS);
    if (this.waits.length !== before) await this.settle(true);
    if (!this.waits.length || this.onScreen > 0) return;
    if (limit > 0 && now - this.lastLook < limit) return;
    this.lastLook = now;

    // Offline is not "no reply": a failed look changes nothing, so a badge the
    // customer has not acted on stays until the page shows them the reply.
    let fresh = false;
    for (const w of this.waits.slice()) {
      const rows = await this.fetchRows(w);
      if (!rows) continue;
      let latest = '';
      for (const row of rows) {
        if (!row || typeof row !== 'object') continue;
        const {from, at} = row as Record<string, unknown>;
        if (from !== 'human' || typeof at !== 'string') continue;
        if (at > w.at && at > latest) latest = at;
      }
      if (latest > w.told) {
        w.told = latest;
        fresh = true;
      }
    }
    await this.settle(true);
    // The customer opened the chat while we were asking: they are reading it.
    if (fresh && this.onScreen === 0 && this.unread) for (const f of Array.from(this.replied)) f();
  }

  private async fetchRows(w: Wait): Promise<unknown[] | null> {
    const query = `?conversationId=${encodeURIComponent(w.c)}${w.at ? `&after=${encodeURIComponent(w.at)}` : ''}`;
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = setTimeout(() => controller?.abort(), TIMEOUT_MS);
    try {
      const response = await fetch(this.messagesUrl + query, {
        headers: {Accept: 'application/json'},
        signal: controller?.signal,
      });
      if (response.status !== 200) return null;
      const json: unknown = await response.json();
      const rows = json && typeof json === 'object' ? (json as {messages?: unknown}).messages : null;
      return Array.isArray(rows) ? rows : [];
    } catch {
      // No network, a captive portal, a server hiccup: the next foreground asks again.
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  private async save(): Promise<void> {
    const storage = this.storage;
    if (!storage) return;
    try {
      if (!this.waits.length) {
        if (storage.removeItem) await storage.removeItem(this.key);
        else await storage.setItem(this.key, '');
        return;
      }
      await storage.setItem(this.key, JSON.stringify({root: this.root, waits: this.waits}));
    } catch {
      // Memory still has it; the next change tries again.
    }
  }
}

const stores = new Map<string, ReplyStore>();

/** The one store for this bot on this server, shared by every chat and hook. */
export function repliesFor(clientId: string, chatUrl: string): ReplyStore {
  const origin = /^(https?:\/\/[^/?#]+)/i.exec(chatUrl)?.[1] ?? '';
  const id = `${chatUrl}`;
  let store = stores.get(id);
  if (!store) {
    store = new ReplyStore(`keyda_bot_waits_${clientId}`, chatUrl, `${origin}/api/business/v1/widget/${clientId}/messages`);
    stores.set(id, store);
  }
  return store;
}

export type {ReplyStore};

export interface KeydaBotRepliesOptions {
  /** Defaults to the platform's own; the same value you give `<KeydaBot>`. */
  baseUrl?: string;
  /**
   * Where to remember the chats waiting for a reply across app restarts:
   * AsyncStorage, or anything with its `getItem`/`setItem`. Without one they
   * are watched only while the app is running.
   */
  storage?: KeydaBotStorage;
  /** A person replied while no chat was on screen. Once per new reply. */
  onReply?: () => void;
}

export interface KeydaBotReplies {
  /** True from a reply found until the chat is opened. */
  hasUnreadReply: boolean;
  /** Ask now (at most once every 10 seconds) rather than at the next foreground. */
  checkForReplies: () => void;
}

/** The hook body, with the chat URL already built and checked by index.tsx. */
export function useReplyStore(store: ReplyStore, options: KeydaBotRepliesOptions): KeydaBotReplies {
  const {storage, onReply} = options;
  const [unread, setUnread] = useState(store.unread);

  useEffect(() => {
    store.useStorage(storage);
  }, [store, storage]);

  useEffect(() => {
    const changed = () => setUnread(store.unread);
    store.changed.add(changed);
    changed();
    return () => {
      store.changed.delete(changed);
    };
  }, [store]);

  // Registered as this hook's own function, which calls the latest onReply:
  // two hooks handed the same module-level function would otherwise share one
  // entry in the set, and the first to unmount would take it from the other.
  const replyRef = useRef(onReply);
  replyRef.current = onReply;
  useEffect(() => {
    const replied = () => {
      if (replyRef.current) replyRef.current();
    };
    store.replied.add(replied);
    return () => {
      store.replied.delete(replied);
    };
  }, [store]);

  useEffect(() => {
    store.look(false);
    const subscription = AppState.addEventListener('change', (next: AppStateStatus) => {
      if (next === 'active') store.look(false);
    });
    return () => subscription.remove();
  }, [store]);

  const checkForReplies = useCallback(() => {
    store.look(true);
  }, [store]);

  return {hasUnreadReply: unread, checkForReplies};
}
