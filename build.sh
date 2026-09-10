#!/bin/bash
# Builds PHPSwitcher.app. Pass --install to also copy it into /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PHPSwitcher"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "==> Building $APP_NAME (release)"
swift build -c release

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/elephant.svg "$APP_BUNDLE/Contents/Resources/elephant.svg"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # Quit a running copy so the bundle can be replaced cleanly.
    osascript -e 'quit app "PHPSwitcher"' 2>/dev/null || true
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_BUNDLE"
    cp -R "$APP_BUNDLE" "/Applications/$APP_BUNDLE"
    echo "    /Applications/$APP_BUNDLE"
fi

echo "==> Done: $(pwd)/$APP_BUNDLE"
