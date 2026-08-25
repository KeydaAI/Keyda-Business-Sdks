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
  execFileSync(TSC, [entry, '--outDir', dir, '--module', 'commonjs', '--target', 'es2019',
    '--skipLibCheck', ...extra], { stdio: 'pipe' });
}

// ── React Native ───────────────────────────────────────────────────────────
try {
  // --noResolve so the peer dependencies it imports do not have to be present.
  compile(join(ROOT, 'react-native', 'src', 'index.tsx'), outRn, ['--jsx', 'react', '--noResolve']);
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
} catch (e) { no(`ionic: ${e.message.split('\n')[0]}`); }

rmSync(outRn, { recursive: true, force: true });
rmSync(outIon, { recursive: true, force: true });
console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
