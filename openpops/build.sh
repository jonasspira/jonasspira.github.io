#!/bin/bash
# Builds OpenPops.app from source.
#
#   ./build.sh              build for this Mac into build/OpenPops.app
#   ./build.sh --install    also copy it to /Applications (or ~/Applications) and open it
#   ./build.sh --zip        also write build/OpenPops.zip
#   ./build.sh --universal  build for Apple silicon and Intel (needs full Xcode)
#
# Only Apple's free Command Line Tools are required: xcode-select --install
# Set OPENPOPS_SIGN_IDENTITY to sign with a certificate from your keychain instead of ad-hoc.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="OpenPops"
VERSION="1.0.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

INSTALL=0
UNIVERSAL=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "OpenPops is a Mac app and has to be built on macOS." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Apple's Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling (release)"
if [ "$UNIVERSAL" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo local)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/__REVISION__/$REVISION/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

IDENTITY="${OPENPOPS_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "==> Signing (ad-hoc)"
else
  echo "==> Signing with \"$IDENTITY\""
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "$ZIP" = 1 ]; then
  echo "==> Zipping"
  rm -f "$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"
fi

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications"
  if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
  fi
  # Quit a running copy. The path match leaves Dock tile apps alone; the new build
  # refreshes them when it starts.
  pkill -TERM -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null && sleep 1 || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  echo "==> Installed $DEST/$APP_NAME.app"
  open "$DEST/$APP_NAME.app"
fi

echo "Done: $APP"
