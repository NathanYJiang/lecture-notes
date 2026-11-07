#!/bin/bash
# Builds a drag-to-Applications DMG in build/.
# For a DMG other people can open without Gatekeeper warnings, set both:
#   SIGN_ID="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<profile saved with: xcrun notarytool store-credentials>
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/LectureNotes-$VERSION.dmg"
STAGING=build/dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/LectureNotes.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Lecture Notes" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${SIGN_ID:-}" && "$SIGN_ID" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "Packaged $DMG"
