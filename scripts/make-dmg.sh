#!/bin/sh
# Packages an app bundle into a compressed, drag-to-install disk image.
# Usage: make-dmg.sh <app bundle> <output .dmg> <volume name>
set -eu

APP=$1
DMG=$2
VOLUME=$3
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG"
