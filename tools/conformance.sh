#!/usr/bin/env bash
# Cross-package conformance.
#
# Six packages, six languages, one contract — and the piece most likely to
# drift silently is the smallest: how a client id is validated and how the
# chat URL is built. Get either wrong and an integrator's customers land on a
# 404 inside what looks like the app's own support screen.
#
# So every package is held to the SAME table here, in its own language,
# rather than to a comment saying they agree.
#
#   bash tools/conformance.sh
#
# Skips any package whose toolchain is not installed and says so — a missing
# Flutter SDK must not read as a passing Flutter package.
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0; SKIP=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip(){ echo "  – $1 (skipped: $2)"; SKIP=$((SKIP+1)); }

GOOD='kb_live_835686cd7c9bf18b9f70c34f'

echo "== the shape every package must agree on =="
# Checked by grep on purpose: this is the one line that must be identical in
# six languages, and reading it is more honest than six separate assertions
# that each package agrees with itself.
# -F, not a pattern: we are looking for this exact TEXT in the source, and
# every regex dialect here writes it identically. Written as a pattern it was
# silently reinterpreted as a BRE and matched nothing, reporting all six
# packages as non-conforming when all six conform.
EXPECTED='kb_live_[0-9a-f]{8,48}'
# iOS validates by hand rather than with NSRegularExpression, so its line is
# the documented shape in a comment; its real behaviour is covered by the
# swift tests below.
for f in android/keyda-bot/src/main/java/in/keyda/bot/KeydaBot.kt \
         ios/Sources/KeydaBot/KeydaBotConfiguration.swift \
         react-native/src/index.tsx \
         ionic/src/config.ts \
         flutter/lib/src/client_id.dart \
         wordpress/keyda-bot/keyda-bot.php; do
  if grep -qF "$EXPECTED" "$f" 2>/dev/null; then ok "$(dirname "$f" | cut -d/ -f1) uses the shared client-id shape"
  else no "$(dirname "$f" | cut -d/ -f1) does NOT use the shared client-id shape"; fi
done

echo "== iOS =="
if command -v swift >/dev/null 2>&1; then
  # From the REPOSITORY ROOT: SPM can only resolve a package whose Package.swift
  # is at the top level, so that is where this one lives; its targets point into
  # ios/.
  if DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test >/dev/null 2>&1; then
    ok "swift test"
  else no "swift test"; fi
else skip "iOS" "no swift toolchain"; fi

[ -f Package.swift ] && ok "Package.swift is at the repo root (SPM cannot read a subdirectory)" \
  || no "Package.swift is not at the repo root — no SPM consumer can install this"
[ -f jitpack.yml ] && ok "jitpack.yml points JitPack at the android build" \
  || no "jitpack.yml missing — JitPack would find no build file"

echo "== Android =="
# The JDK is checked BEFORE the build, because the failure it causes is
# unreadable: Gradle 8.13 on a JDK newer than 21 dies with a bare version
# string and no explanation. Android Studio's bundled JBR is currently a
# JDK 25, so a developer whose shell inherits JAVA_HOME from Studio hits this
# without having done anything wrong.
JDK_MAJOR=""
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
  JDK_MAJOR=$("${JAVA_HOME}/bin/java" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
fi
if [ -z "${JAVA_HOME:-}" ] || [ -z "${ANDROID_HOME:-}" ]; then
  skip "Android" "set JAVA_HOME (a JDK 17) and ANDROID_HOME"
elif [ -n "$JDK_MAJOR" ] && [ "$JDK_MAJOR" -gt 21 ] 2>/dev/null; then
  skip "Android" "JAVA_HOME is a JDK $JDK_MAJOR; Gradle 8.13 needs 17-21 (brew install openjdk@17)"
elif (cd android && ./gradlew :keyda-bot:assembleRelease --no-daemon -q >/dev/null 2>&1); then
  ok "gradle assembleRelease"
else
  no "gradle assembleRelease"
fi

echo "== Flutter =="
if command -v flutter >/dev/null 2>&1; then
  if (cd flutter && flutter test >/dev/null 2>&1); then ok "flutter test"; else no "flutter test"; fi
else skip "Flutter" "no flutter SDK"; fi

echo "== WordPress =="
if command -v php >/dev/null 2>&1; then
  php -l wordpress/keyda-bot/keyda-bot.php >/dev/null 2>&1 && \
  php -l wordpress/keyda-bot/includes/settings.php >/dev/null 2>&1 && \
  php -l wordpress/keyda-bot/uninstall.php >/dev/null 2>&1 \
    && ok "php -l on every plugin file" || no "php -l"
  # A settings form without a nonce and a capability check is a CSRF hole.
  grep -q 'check_admin_referer\|wp_verify_nonce\|settings_fields' wordpress/keyda-bot/includes/settings.php \
    && ok "settings form is nonce-protected" || no "settings form has no nonce"
  grep -q "current_user_can" wordpress/keyda-bot/includes/settings.php \
    && ok "settings page checks capability" || no "settings page has no capability check"
else skip "WordPress" "no php"; fi

echo "== React Native and Ionic behaviour =="
# Needs a TypeScript compiler. Prefer one already on the machine over an npx
# download, and skip rather than pretend if there is none.
TSC=""
for cand in ./node_modules/.bin/tsc \
            "$HOME/Projects/Keyda/keyda-backend/node_modules/.bin/tsc" \
            "$(command -v tsc 2>/dev/null)"; do
  [ -x "$cand" ] && TSC="$cand" && break
done
if [ -n "$TSC" ]; then
  if node tools/js-conformance.mjs "$TSC"; then :; else FAIL=$((FAIL+1)); fi
else skip "React Native / Ionic" "no tsc on PATH"; fi

echo "== the rule that keeps a conversation alive =="
# Compared by PATH, never by origin alone. The chat's own "Powered by Keyda"
# link is built from the widget's script origin, so on the default deployment
# it is the SAME ORIGIN as the chat page. An origin check calls it "ours", the
# WebView navigates in place, and the customer's conversation is replaced by a
# marketing site with no way back — the widget re-greets on mount and persists
# nothing but a session id, so every message on screen is gone.
#
# This was live in two packages at once and looked correct in both.
grep -q "isChatPage" android/keyda-bot/src/main/java/in/keyda/bot/KeydaBotActivity.kt 2>/dev/null \
  && ok "android compares the chat PATH, not just the origin" || no "android compares origin only"
grep -q "staysInChat" ios/Sources/KeydaBot/KeydaBotConfiguration.swift 2>/dev/null \
  && ok "ios compares the chat PATH, not just the origin" || no "ios compares origin only"
grep -q "staysInChat" react-native/src/index.tsx 2>/dev/null \
  && ok "react-native compares the chat PATH, not just the origin" || no "react-native compares origin only"
grep -q "staysInChat" flutter/lib/src/client_id.dart 2>/dev/null \
  && ok "flutter compares the chat PATH, not just the origin" || no "flutter compares origin only"
grep -q "isSameOrigin" flutter/lib/src/*.dart 2>/dev/null \
  && no "flutter still has an origin-only comparison" || ok "flutter has no origin-only comparison left"

# A link that navigates the chat WebView away replaces the customer's
# conversation with a marketing page and gives them no way back. Every
# package must hand other-origin navigation to the system browser.
grep -q "ACTION_VIEW" android/keyda-bot/src/main/java/in/keyda/bot/*.kt 2>/dev/null \
  && ok "android escapes navigation to the browser" || no "android does not escape navigation"
grep -q "UIApplication.shared.open\|open(url" ios/Sources/KeydaBot/*.swift 2>/dev/null \
  && ok "ios escapes navigation to the browser" || no "ios does not escape navigation"
grep -q "Linking.openURL" react-native/src/*.tsx 2>/dev/null \
  && ok "react-native escapes navigation to the browser" || no "react-native does not escape navigation"

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
