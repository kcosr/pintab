#!/bin/sh
# Assembles and signs PinTab.app from a SwiftPM-built executable.
# Usage: make-app.sh <executable> <output .app path>
# Environment: APP_NAME, BUNDLE_ID, VERSION, SIGN_IDENTITY ("-" for ad-hoc).
set -eu

EXECUTABLE=$1
APP=$2
APP_NAME=${APP_NAME:-PinTab}
BUNDLE_ID=${BUNDLE_ID:-dev.local.PinTab}
VERSION=${VERSION:-0.1.0}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/@APP_NAME@/$APP_NAME/g" \
    -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
    -e "s/@VERSION@/$VERSION/g" \
    "$ROOT/Support/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

if [ -f "$ROOT/Support/AppIcon.icns" ]; then
    cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# The linker already ad-hoc signs the bare executable under its file name; re-sign the whole bundle
# so the signature carries the bundle identifier.
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($BUNDLE_ID $VERSION, signed with '$SIGN_IDENTITY')"
