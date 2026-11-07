#!/bin/bash
# Builds build/LectureNotes.app.
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh   → release-signed (hardened runtime)
#   scripts/make-dev-cert.sh once                                  → local builds stop re-triggering permission prompts
#   ./build.sh --install                                           → also copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LectureNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/LectureNotes" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-$(cat google-client-id.txt 2>/dev/null || true)}"
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :GoogleClientID string $GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
else
    echo "warning: no google-client-id.txt — Google sign-in will be disabled in this build"
fi

# A stable local identity (scripts/make-dev-cert.sh) keeps macOS from re-asking for
# Keychain and mic access after every rebuild. Ad-hoc signing changes identity each build.
DEV_ID="LectureNotes Dev"
if [[ -z "${SIGN_ID:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEV_ID\""; then
    SIGN_ID="$DEV_ID"
fi
SIGN_ID="${SIGN_ID:--}"
if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --sign - "$APP"
elif [[ "$SIGN_ID" == "$DEV_ID" ]]; then
    codesign --force --entitlements Resources/LectureNotes.entitlements --sign "$DEV_ID" "$APP" \
        || { echo "warning: signing with \"$DEV_ID\" failed, falling back to ad-hoc"; SIGN_ID="-"; codesign --force --sign - "$APP"; }
else
    codesign --force --options runtime --timestamp \
        --entitlements Resources/LectureNotes.entitlements --sign "$SIGN_ID" "$APP"
fi
echo "Built $APP (signed: $SIGN_ID)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LectureNotes || true
    rm -rf /Applications/LectureNotes.app
    cp -R "$APP" /Applications/
    open /Applications/LectureNotes.app
    echo "Installed to /Applications"
fi
