#!/bin/bash
# Runs OpenPops' built-in self-test, then launches the built app the way the Dock does
# and checks the log. Used by CI; also works locally after ./build.sh.
# Screenshots and logs go to build/self-test/.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/OpenPops.app"
OUT="$PWD/build/self-test"
SUPPORT="$HOME/Library/Application Support/OpenPops"
status=0

if [ ! -d "$APP" ]; then
  echo "Build the app first: ./build.sh" >&2
  exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> In-app self-test"
"$APP/Contents/MacOS/OpenPops" --self-test "$OUT" 2>&1 | tee "$OUT/self-test.log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then status=1; fi

echo "==> Launch and reopen smoke test"
mkdir -p "$SUPPORT"
if [ -f "$SUPPORT/library.json" ]; then mv "$SUPPORT/library.json" "$SUPPORT/library.smoke-backup.json"; fi
touch "$SUPPORT/debug-log-enabled"
: > "$SUPPORT/debug.log"

open "$APP"                               # first launch: starter Pops + Organizer
sleep 6
screencapture -x "$OUT/smoke-1-first-launch.png" 2>/dev/null || true
open "$APP"                               # what a click on the running app's Dock icon sends
sleep 3
screencapture -x "$OUT/smoke-2-reopen.png" 2>/dev/null || true
open "openpops://show?pop=Utilities"
sleep 3
screencapture -x "$OUT/smoke-3-url-show.png" 2>/dev/null || true
pkill -f "/OpenPops.app/Contents/MacOS/OpenPops" 2>/dev/null || true
sleep 1

cp "$SUPPORT/debug.log" "$OUT/smoke-debug.log" 2>/dev/null || true
cp "$SUPPORT/library.json" "$OUT/smoke-library.json" 2>/dev/null || true
for want in "created [0-9]+ starter pops" "organizer shown" "reopen" "popover shown" "url command openpops://show"; do
  if grep -Eq "$want" "$OUT/smoke-debug.log"; then
    echo "ok   smoke: $want"
  else
    echo "FAIL smoke: $want"
    status=1
  fi
done

rm -f "$SUPPORT/library.json"
if [ -f "$SUPPORT/library.smoke-backup.json" ]; then mv "$SUPPORT/library.smoke-backup.json" "$SUPPORT/library.json"; fi
rm -f "$SUPPORT/debug-log-enabled"
exit $status
