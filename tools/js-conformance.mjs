#!/usr/bin/env node
// Runs the React Native and Ionic packages' PURE helpers against the same
// table every other package is held to.
//
// The React parts need a device; these two functions do not — and they are
// the ones where a wrong answer sends an integrator's customers to a 404
// inside what looks like the app's own support screen. React Native's peer
// modules are stubbed rather than installed: this is testing OUR logic, and
// pulling ~200MB of react-native to check a regex would be its own mistake.
//
// Usage: node tools/js-conformance.mjs <path-to-tsc>
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const TSC = process.argv[2] || 'tsc';
// One directory per package. Sharing one meant both compiled to index.js,
// and require's cache then handed the second package the FIRST package's
// module — reporting "chatUrl is not a function" for code that exports it.
const outRn = mkdtempSync(join(tmpdir(), 'keyda-conf-rn-'));
const outIon = mkdtempSync(join(tmpdir(), 'keyda-conf-ion-'));
const GOOD = 'kb_live_835686cd7c9bf18b9f70c34f';
let pass = 0; let fail = 0;
const ok = (m) => { console.log(`  ✓ ${m}`); pass++; };
const no = (m) => { console.log(`  ✗ ${m}`); fail++; };

function compile(entry, dir, extra = []) {
  const entries = Array.isArray(entry) ? entry : [entry];
  execFileSync(TSC, [...entries, '--outDir', dir, '--module', 'commonjs', '--target', 'es2019',
    '--skipLibCheck', ...extra], { stdio: 'pipe' });
}

// ── React Native ───────────────────────────────────────────────────────────
try {
  // --noResolve so the peer dependencies it imports do not have to be present.
  compile(['index.tsx', 'replies.ts', 'visitor.ts'].map((f) => join(ROOT, 'react-native', 'src', f)), outRn, ['--jsx', 'react', '--noResolve']);
} catch (e) {
  // tsc exits non-zero on the missing peers even with --noResolve; the JS is
  // still emitted, which is what we run.
}
const require_ = createRequire(import.meta.url);
const Module = require_('module');
const load = Module._load;
Module._load = function (req, ...rest) {
  if (req === 'react') return { createElement: () => null, useState: () => [null, () => {}], useCallback: (f) => f, useMemo: (f) => f(), useRef: () => ({ current: null }), useEffect: () => {} };
  if (req === 'react-native') return new Proxy({ StyleSheet: { create: (x) => x }, Linking: { openURL: () => {} }, Platform: { OS: 'ios' } }, { get: (t, k) => (k in t ? t[k] : String(k)) });
  if (req === 'react-native-webview') return { WebView: 'WebView' };
  return load.call(this, req, ...rest);
};

const ID_CASES = [
  [GOOD, true], [`kb_live_${'a'.repeat(8)}`, true], [`kb_live_${'a'.repeat(48)}`, true],
  [`kb_live_${'a'.repeat(7)}`, false], [`kb_live_${'a'.repeat(49)}`, false],
  ['kb_live_ABCDEF12', false], ['kb_test_abcdef12', false], ['', false],
  [`${GOOD}\n`, false], [` ${GOOD}`, false], [null, false], [undefined, false],
];
const URL_CASES = [
  [undefined, `https://keyda.in/business/chat/${GOOD}`],
  ['https://keyda.in/business', `https://keyda.in/business/chat/${GOOD}`],
  ['https://keyda.in/business/', `https://keyda.in/business/chat/${GOOD}`],
  ['https://keyda.in/business', `https://keyda.in/business/chat/${GOOD}`],
  ['https://keyda.in/business/', `https://keyda.in/business/chat/${GOOD}`],
];

try {
  const rn = require_(join(outRn, 'index.js'));
  let bad = 0;
  for (const [v, want] of ID_CASES) if (rn.isValidClientId(v) !== want) { bad++; console.log(`      isValidClientId(${JSON.stringify(v)}) wrong`); }
  for (const [base, want] of URL_CASES) {
    const got = base === undefined ? rn.buildChatUrl(GOOD) : rn.buildChatUrl(GOOD, base);
    if (got !== want) { bad++; console.log(`      buildChatUrl(base=${base}) = ${got}`); }
  }
  bad === 0 ? ok(`react-native: ${ID_CASES.length + URL_CASES.length} cases`) : no(`react-native: ${bad} wrong`);
} catch (e) { no(`react-native: ${e.message.split('\n')[0]}`); }

// ── React Native: the visitor ─────────────────────────────────────────────
// Every SDK and the page drop exactly the same values, whole: a name of 1–80
// characters on one line, a phone with 8–15 digits, an email that looks like
// one. Built from code points: a lone half cannot be written in a source file.
try {
  const V = require_(join(outRn, 'visitor.js'));
  const half = String.fromCharCode(0xd83d); const grin = String.fromCodePoint(0x1f600);
  const zwj = String.fromCharCode(0x200d); const shy = String.fromCharCode(0xad);
  const cases = [
    ['name', '  Asha \n Rao ', 'Asha Rao'], ['name', 'a'.repeat(80), 'a'.repeat(80)], ['name', 'a'.repeat(81), ''],
    ['name', grin.repeat(80), grin.repeat(80)], ['name', `Asha${String.fromCharCode(0, 1, 0x7f)}Rao`, 'Asha Rao'],
    ['name', `Asha${half} Rao`, 'Asha Rao'], ['name', `A${zwj}B${shy}C`, `A${zwj}B${shy}C`], ['name', ' \t ', ''],
    ['phone', ' 9876 5432 ', '9876 5432'], ['phone', '987 6543', ''], ['phone', '+1 (234) 567-8901.234', '+1 (234) 567-8901.234'],
    ['phone', '1234567890123456', ''], ['phone', '+0 98765 43210', ''], ['phone', '9  '.repeat(12), ''], ['phone', 'call me', ''],
    ['email', ' asha@example.co.in ', 'asha@example.co.in'], ['email', 'asha@example.c', ''], ['email', 'asha..rao@example.com', ''],
    ['email', 'x@y', ''], ['email', `${'a'.repeat(242)}@example.com`, `${'a'.repeat(242)}@example.com`], ['email', `${'a'.repeat(243)}@example.com`, ''],
  ];
  let bad = 0;
  for (const [field, value, want] of cases) {
    const got = (V.cleanVisitor({ [field]: value }) || { [field]: '' })[field];
    if (got !== want) { bad++; console.log(`      ${field} ${JSON.stringify(value)} -> ${JSON.stringify(got)}`); }
  }
  if (V.cleanVisitor({ name: 'a'.repeat(81), phone: '12', email: 'x@y' }) !== null) { bad++; console.log('      nothing usable is not null'); }
  bad === 0 ? ok(`react-native: visitor, ${cases.length + 1} cases`) : no(`react-native: visitor, ${bad} wrong`);
} catch (e) { no(`react-native visitor: ${e.message.split('\n')[0]}`); }

// ── React Native: a team reply while the chat is closed ────────────────────
// The store against a stand-in for /widget/{id}/messages: unread and one
// onReply for a reply, none repeated, none while a chat is on screen, none
// once the page has shown it; offline changes nothing. A chat loaded out of
// sight that draws the reply has not shown it to anyone.
try {
  const R = require_(join(outRn, 'replies.js'));
  const http = await import('node:http');
  let rows = []; let calls = 0; let down = false; let lastAfter = null;
  const srv = http.createServer((req, res) => {
    calls++;
    if (down) { res.writeHead(503); res.end(); return; }
    lastAfter = new URL(req.url, 'http://x').searchParams.get('after');
    const after = lastAfter || '';
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ messages: rows.filter((r) => r.at > after) }));
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const C = '1fe085d4-e386-4200-893c-237e021b2308';
  const base = `http://127.0.0.1:${srv.address().port}`;
  const store = R.repliesFor(GOOD, `${base}/business/chat/${GOOD}`);
  let told = 0; store.replied.add(() => told++);
  const realNow = Date.now; let skew = 0; Date.now = () => realNow() + skew;
  const later = async (ms) => { skew += ms; };
  // Lets the store's queue run; nothing in it waits on the network here.
  const settle = () => new Promise((r) => setTimeout(r, 20));
  const steps = [];
  const t0 = realNow();
  const X = '2026-10-09T15:54:41.019Z'; const Y = '2026-10-09T16:10:00.000Z'; const Z = '2026-10-09T16:20:00.000Z';
  store.onWaits([{ c: C, at: '', t: t0 }, { c: 'nope', at: '', t: t0 }, { c: C.replace('1f', '2f'), at: '', t: t0 - 15 * 864e5 }], true);
  await store.look(false); steps.push(['nothing yet', !store.unread && told === 0 && calls === 1]);
  rows = [{ from: 'human', at: X }];
  await store.look(true); steps.push(['forced inside 10 s asks nothing', calls === 1]);
  await later(61_000); await store.look(false); steps.push(['a reply: unread, told once', store.unread && told === 1]);
  await later(61_000); await store.look(false); steps.push(['not told twice', told === 1 && store.unread]);
  store.chatAppeared(); steps.push(['opening the chat clears it at once', !store.unread]);
  await later(61_000); await store.look(false); steps.push(['no request while on screen', calls === 3]);
  store.onWaits([{ c: C, at: X, t: t0 }], true); store.chatWentAway();
  await store.look(false); steps.push(['shown by the page: not unread', !store.unread]);
  rows.push({ from: 'human', at: Y }); down = true;
  await later(61_000); await store.look(false); steps.push(['offline changes nothing', !store.unread && told === 1]);
  // Out of sight, the page moves its place for any row; only a person's
  // counts. `look(false)` here only waits for the queue: inside the minute.
  down = false; rows = [{ from: 'human', at: X }, { from: 'order', at: Y }];
  const before = calls;
  store.onWaits([{ c: C, at: Y, t: t0 }], false); await store.look(false);
  steps.push(['out of sight, the page moved on: asked at once', calls === before + 1 && lastAfter === X]);
  steps.push(["an order's status out of sight lights nothing", !store.unread && told === 1]);
  rows.push({ from: 'human', at: Z });
  store.onWaits([{ c: C, at: Z, t: t0 }], false); await store.look(false);
  steps.push(["a person's reply out of sight: unread, told once", store.unread && told === 2 && calls === before + 2]);
  store.onWaits([{ c: C, at: Z, t: t0 }], false); await store.look(false);
  steps.push(['the page did not move: nothing asked, still unread', calls === before + 2 && told === 2 && store.unread]);
  store.chatAppeared(); await settle(); store.chatWentAway(); await settle();
  steps.push(['a chat appearing catches up with the page', !store.unread]);
  await later(61_000); await store.look(false);
  steps.push(['and asks after it from then on', lastAfter === Z && !store.unread]);

  // A list the page sent before the host's storage arrived reaches disk, and
  // what disk knew was told is kept: an old "told past the place" written
  // there before must not come back at the next cold start.
  const disk = new Map();
  const storage = { getItem: async (k) => disk.get(k) ?? null, setItem: async (k, v) => { disk.set(k, v); }, removeItem: async (k) => { disk.delete(k); } };
  const root2 = `${base}/other/chat/${GOOD}`;
  disk.set(`keyda_bot_waits_${GOOD}`, JSON.stringify({ root: root2, waits: [{ c: C, at: '', t: t0, told: X }] }));
  const early = R.repliesFor(GOOD, root2);
  early.onWaits([{ c: C, at: X, t: t0 }], true);
  early.useStorage(storage); await settle();
  const saved = JSON.parse(disk.get(`keyda_bot_waits_${GOOD}`) || '{}').waits || [];
  steps.push(['a list sent before the storage is saved', saved.length === 1 && saved[0].at === X && saved[0].page === X && saved[0].told === X && !early.unread]);

  // One saved before `page` existed loads at its own place: unread, and a
  // chat appearing does not by itself make it seen.
  disk.set(`keyda_bot_waits_${GOOD}`, JSON.stringify({ root: `${base}/third/chat/${GOOD}`, waits: [{ c: C, at: '', t: t0, told: X }] }));
  const old = R.repliesFor(GOOD, `${base}/third/chat/${GOOD}`);
  old.useStorage(storage); await settle();
  const loaded = old.unread;
  old.chatAppeared(); await settle(); old.chatWentAway(); await settle();
  steps.push(['an older saved list loads; appearing alone does not clear it', loaded && old.unread]);

  Date.now = realNow; srv.close();
  const wrong = steps.filter(([, good]) => !good);
  for (const [name] of wrong) console.log(`      ${name}`);
  wrong.length === 0 ? ok(`react-native: replies, ${steps.length} steps`) : no(`react-native: replies, ${wrong.length} wrong`);
} catch (e) { no(`react-native replies: ${e.message.split('\n')[0]}`); }

// ── Ionic / Capacitor ──────────────────────────────────────────────────────
try {
  compile(join(ROOT, 'ionic', 'src', 'index.ts'), outIon, ['--moduleResolution', 'node']);
  const ion = require_(join(outIon, 'index.js'));
  let bad = 0;
  for (const [base, want] of URL_CASES) {
    const got = base === undefined ? ion.chatUrl(GOOD) : ion.chatUrl(GOOD, base);
    if (got !== want) { bad++; console.log(`      chatUrl(base=${base}) = ${got}`); }
  }
  for (const [v, valid] of ID_CASES) {
    if (typeof v !== 'string') continue;
    let threw = false;
    try { ion.chatUrl(v); } catch { threw = true; }
    if (threw === valid) { bad++; console.log(`      chatUrl(${JSON.stringify(v)}) ${threw ? 'threw' : 'accepted'} wrongly`); }
  }
  bad === 0 ? ok('ionic: url building and id validation') : no(`ionic: ${bad} wrong`);

  // A question cut through an emoji used to make open() THROW (URIError from
  // encodeURIComponent on half a character). A visitor never rides along:
  // the full screen is the system browser, whose history keeps the URL.
  let opened = '';
  globalThis.window = { open: (u) => { opened = u; return {}; } };
  const warn = console.warn; console.warn = () => {};
  let threw = '';
  try {
    await ion.KeydaBot.open({ clientId: GOOD, question: 'a'.repeat(499) + '\u{1F600}x', visitor: { name: 'Asha & Co', phone: '+91 98765 43210', email: 'asha@example.com' } });
  } catch (e) { threw = e.message; }
  const frag = new URLSearchParams(opened.split('#')[1] || '');
  const q = frag.get('q') || '';
  const good = !threw && Array.from(q).length === 500 && q.endsWith('\u{1F600}') && [...frag.keys()].join() === 'q' && !/Asha|98765|example/.test(opened);
  good ? ok('ionic: open() with an emoji at the cut; no visitor in the link') : no(`ionic: open() ${threw || opened}`);

  // open() over init(), not instead of it: a staging init() stays staging,
  // and a call with no client id of its own uses the stored one.
  const staging = 'https://staging.example.com/business';
  threw = '';
  const urls = [];
  try {
    ion.KeydaBot.init(GOOD, staging);
    await ion.KeydaBot.open({ clientId: GOOD }); urls.push(opened);
    await ion.KeydaBot.open({ question: 'Is it in stock?' }); urls.push(opened);
    await ion.KeydaBot.open(); urls.push(opened);
  } catch (e) { threw = e.message; }
  const want = `${staging}/chat/${GOOD}`;
  const kept = !threw && urls.length === 3 && urls[0] === want && urls[1] === `${want}#q=Is%20it%20in%20stock%3F` && urls[2] === want;
  kept ? ok("ionic: open() keeps init()'s client id and server") : no(`ionic: open() after init() ${threw || urls.join(' ')}`);
  console.warn = warn;
  delete globalThis.window;
} catch (e) { no(`ionic: ${e.message.split('\n')[0]}`); }

rmSync(outRn, { recursive: true, force: true });
rmSync(outIon, { recursive: true, force: true });
console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
