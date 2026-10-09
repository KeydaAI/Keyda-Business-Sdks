#!/usr/bin/env node
// One version for all six packages, written in every place that carries it.
//
//   node tools/release.mjs check [vX.Y.Z]   every place agrees (and matches the tag)
//   node tools/release.mjs bump X.Y.Z       write X.Y.Z everywhere, open a changelog entry
//   node tools/release.mjs date [YYYY-MM-DD] date the open changelog entries (default: today, UTC)
//
// A release is: bump, write the changelog entries, date, commit, tag vX.Y.Z,
// push the tag. CI runs `check` on every push; the release workflow runs
// `check vX.Y.Z` before it publishes anything, so a tag that disagrees with
// any package publishes nothing.
//
// Every place is named below with the exact text around the number. A place
// that no longer matches is an error, never a skip: a README that changed
// shape would otherwise keep quoting the old version while this reports
// success.
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const N = '(\\d+\\.\\d+\\.\\d+)';

// [file, pattern with the version as group 2 (group 1 before it, group 3
// after it), how many times it appears]
const PLACES = [
  ['KeydaBot.podspec', `(s\\.version\\s*=\\s*')${N}(')`, 1],
  ['android/keyda-bot/build.gradle.kts', `(val sdkVersion = ")${N}(")`, 1],
  ['android/README.md', `(keyda-business-sdks:v)${N}()`, 1],
  ['android/README.md', `(\`v)${N}(\` resolves today)`, 1],
  ['android/README.md', `(in\\.keyda:keyda-bot:)${N}()`, 3],
  ['ios/README.md', `(from: ")${N}(")`, 1],
  ['ios/README.md', `(keyda-business-sdks/v)${N}(/KeydaBot\\.podspec)`, 1],
  ['react-native/package.json', `(\\n  "version": ")${N}(")`, 1],
  ['react-native/src/index.tsx', `(const SDK_VERSION = ')${N}(')`, 1],
  ['flutter/pubspec.yaml', `(\\nversion: )${N}(\\n)`, 1],
  ['flutter/lib/src/sdk_version.dart', `(kKeydaSdkVersion = ')${N}(')`, 1],
  ['flutter/README.md', `(keyda_bot: \\^)${N}()`, 1],
  ['ionic/package.json', `(\\n  "version": ")${N}(")`, 1],
  // npm writes the package's own version twice into its lockfile.
  ['ionic/package-lock.json', `("name": "@keyda/bot-capacitor",\\n\\s+"version": ")${N}(")`, 2],
  ['wordpress/keyda-bot/keyda-bot.php', `(\\n \\* Version:\\s+)${N}(\\n)`, 1],
  ['wordpress/keyda-bot/readme.txt', `(\\nStable tag: )${N}(\\n)`, 1],
  ['wordpress/README.md', `(/keyda-bot-)${N}(\\.zip)`, 1],
  ['wordpress/README.md', `("tags/)${N}(")`, 1],
  ['wordpress/README.md', `("Release )${N}(")`, 1],
  ['README.md', `(keyda-business-sdks:v)${N}()`, 1],
  ['README.md', `(at tag \`v)${N}(\`)`, 1],
  ['README.md', `(bot-react-native@)${N}()`, 1],
  ['README.md', `(keyda_bot \\^)${N}()`, 1],
  ['README.md', `(bot-capacitor@)${N}()`, 1],
  ['README.md', `(\`wordpress/keyda-bot/\`, )${N}(\\))`, 1],
];

// `## X.Y.Z — unreleased` or `## X.Y.Z — 2026-10-09`, newest first.
const CHANGELOGS = ['android', 'ios', 'react-native', 'flutter', 'ionic'].map((p) => `${p}/CHANGELOG.md`);
const WP_README = 'wordpress/keyda-bot/readme.txt';

// Every pattern here is written for "\n". A file saved with Windows line
// endings is read as "\n" and written back the way it came.
const crlf = new Set();
const read = (f) => {
  const text = readFileSync(join(ROOT, f), 'utf8');
  if (text.includes('\r\n')) crlf.add(f);
  return text.replace(/\r\n/g, '\n');
};
const write = (f, s) => writeFileSync(join(ROOT, f), crlf.has(f) ? s.replace(/\n/g, '\r\n') : s);
const isVersion = (v) => /^\d+\.\d+\.\d+$/.test(v);
/// a < b, by number: 0.10.0 is newer than 0.9.0.
const older = (a, b) => {
  const x = a.split('.').map(Number);
  const y = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i];
  return false;
};
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function die(message) {
  console.error(`release: ${message}`);
  process.exit(1);
}

/// Every place, with what it says now.
function scan() {
  const found = [];
  const problems = [];
  for (const [file, pattern, count] of PLACES) {
    const hits = [...read(file).matchAll(new RegExp(pattern, 'g'))].map((m) => m[2]);
    if (hits.length !== count) {
      problems.push(`${file}: expected ${count} × /${pattern}/, found ${hits.length} — update PLACES in tools/release.mjs`);
    }
    for (const v of hits) found.push({ file, v });
  }
  return { found, problems };
}

/// The entry for `version` in a Markdown changelog: its heading's date
/// ('unreleased' or YYYY-MM-DD) and whether it says anything.
function changelogEntry(text, version) {
  const lines = text.split('\n');
  const at = lines.findIndex((l) => new RegExp(`^## ${escape(version)}( |$)`).test(l));
  if (at < 0) return null;
  const first = lines.findIndex((l) => l.startsWith('## '));
  let end = lines.findIndex((l, i) => i > at && l.startsWith('## '));
  if (end < 0) end = lines.length;
  const date = (lines[at].match(/ — (.+)$/) || [])[1] || '';
  return { newest: first === at, date, written: lines.slice(at + 1, end).some((l) => l.trim()) };
}

/// The `= X.Y.Z =` entry under readme.txt's == Changelog ==.
function wordpressEntry(text, version) {
  const log = text.split(/^== Changelog ==$/m)[1];
  if (log === undefined) return null;
  const section = log.split(/^== /m)[0];
  const parts = section.split(/^= (\d+\.\d+\.\d+) =$/m);
  // ['', '0.2.0', '* …', '0.1.4', '* …', …]
  const i = parts.indexOf(version);
  if (i < 0) return null;
  return { newest: i === 1, written: parts[i + 1].trim().length > 0 };
}

function check(tag) {
  const { found, problems } = scan();
  const versions = [...new Set(found.map((x) => x.v))];
  if (versions.length > 1) {
    for (const v of versions) {
      problems.push(`${v} in ${[...new Set(found.filter((x) => x.v === v).map((x) => x.file))].join(', ')}`);
    }
  }
  const version = versions.length === 1 ? versions[0] : null;
  if (tag !== undefined) {
    if (!/^v\d+\.\d+\.\d+$/.test(tag)) problems.push(`"${tag}" is not a release tag (vX.Y.Z)`);
    else if (version && tag !== `v${version}`) problems.push(`the tag is ${tag} but the packages say ${version}`);
  }
  if (version) {
    for (const file of CHANGELOGS) {
      const e = changelogEntry(read(file), version);
      if (!e) problems.push(`${file}: no "## ${version}" entry`);
      else {
        if (!e.newest) problems.push(`${file}: "## ${version}" is not the newest entry`);
        if (!e.written) problems.push(`${file}: the ${version} entry is empty`);
        if (tag !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(e.date)) {
          problems.push(`${file}: the ${version} entry is "${e.date || 'undated'}" — run \`node tools/release.mjs date\` before tagging`);
        }
      }
    }
    const wp = wordpressEntry(read(WP_README), version);
    if (!wp) problems.push(`${WP_README}: no "= ${version} =" under == Changelog ==`);
    else {
      if (!wp.newest) problems.push(`${WP_README}: "= ${version} =" is not the newest changelog entry`);
      if (!wp.written) problems.push(`${WP_README}: the ${version} changelog entry is empty`);
    }
  }
  if (problems.length) {
    console.error('release check failed:');
    for (const p of problems) console.error(`  ✗ ${p}`);
    process.exit(1);
  }
  console.log(`release check: all six packages at ${version}${tag ? `, matching ${tag}` : ''} (${found.length} places, ${CHANGELOGS.length + 1} changelogs)`);
}

function bump(next) {
  if (!isVersion(next)) die(`"${next}" is not X.Y.Z`);
  const { found, problems } = scan();
  if (problems.length) die(`fix these first:\n  ${problems.join('\n  ')}`);
  // Versions only go up: 0.1.9 typed for 0.2.9 would otherwise be written
  // everywhere and pass every check after it.
  const dated = CHANGELOGS.flatMap((file) => [...read(file).matchAll(/^## (\d+\.\d+\.\d+) — \d{4}-\d{2}-\d{2}$/gm)].map((m) => m[1]));
  const floor = [...found.map((x) => x.v), ...dated].reduce((a, b) => (older(a, b) ? b : a), '0.0.0');
  if (older(next, floor)) die(`${next} is older than ${floor}, which is already in this repo`);
  if (dated.includes(next) && found.some((x) => x.v !== next)) die(`${next} is already dated in a changelog: it has been released`);
  const changed = new Set();
  let renamed = null;
  for (const [file, pattern] of PLACES) {
    const before = read(file);
    const after = before.replace(new RegExp(pattern, 'g'), (_, a, _v, b) => `${a}${next}${b}`);
    if (after !== before) { write(file, after); changed.add(file); }
  }
  // An open entry under another number (0.1.5 that became 0.2.0) is renamed;
  // a dated one stays, with a new open entry above it for the text.
  for (const file of CHANGELOGS) {
    const before = read(file);
    let after = before;
    if (!changelogEntry(before, next)) {
      const open = before.match(/^## (\d+\.\d+\.\d+) — unreleased$/m);
      if (open) renamed = open[1];
      after = open
        ? before.replace(open[0], `## ${next} — unreleased`)
        : before.replace(/^## /m, `## ${next} — unreleased\n\n## `);
    }
    if (after !== before) { write(file, after); changed.add(file); }
  }
  // readme.txt has no "unreleased": its newest entry is the open one when the
  // Markdown changelogs had one, and moves with them.
  const wp = read(WP_README);
  if (!wordpressEntry(wp, next)) {
    const open = renamed && wordpressEntry(wp, renamed);
    const after = open && open.newest
      ? wp.replace(`\n= ${renamed} =\n`, `\n= ${next} =\n`)
      : wp.replace(/^(== Changelog ==\n\n)/m, `$1= ${next} =\n\n`);
    if (after !== wp) { write(WP_README, after); changed.add(WP_README); }
    else console.error(`release: could not add "= ${next} =" to ${WP_README} — add it under == Changelog == by hand`);
  }
  console.log(changed.size ? `bumped to ${next}:\n  ${[...changed].join('\n  ')}` : `already at ${next}`);
  console.log('Next: write each changelog entry, run `node tools/release.mjs date`, commit, tag, push the tag.');
}

function date(day) {
  const today = day ?? new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) die(`"${today}" is not YYYY-MM-DD`);
  let n = 0;
  for (const file of CHANGELOGS) {
    const before = read(file);
    const after = before.replace(/^(## \d+\.\d+\.\d+) — unreleased$/m, `$1 — ${today}`);
    if (after !== before) { write(file, after); n++; }
  }
  console.log(n ? `dated ${n} changelog entr${n === 1 ? 'y' : 'ies'} ${today}` : 'no open changelog entry to date');
}

const [command, arg] = process.argv.slice(2);
if (command === 'check') check(arg);
else if (command === 'bump') bump(arg ?? '');
else if (command === 'date') date(arg);
else die('usage: node tools/release.mjs check [vX.Y.Z] | bump X.Y.Z | date [YYYY-MM-DD]');
