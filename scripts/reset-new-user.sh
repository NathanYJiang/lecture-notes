#!/bin/bash
# Makes this Mac look like a brand-new install, for testing onboarding.
# Recordings are moved to the Desktop, not deleted. API keys and Google sign-in ARE removed.
set -euo pipefail

BUNDLE=com.nathanjiang.LectureNotes
DATA="$HOME/Library/Application Support/LectureNotes"

read -r -p "Quit Lecture Notes and reset it to a first-run state? Your saved AI key will be removed. [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0

osascript -e 'quit app "LectureNotes"' 2>/dev/null || true
sleep 1

if [ -d "$DATA" ]; then
    BACKUP="$HOME/Desktop/LectureNotes-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$DATA" "$BACKUP"
    echo "Recordings moved to $BACKUP"
fi

defaults delete "$BUNDLE" 2>/dev/null || true
while security delete-generic-password -s "$BUNDLE" >/dev/null 2>&1; do :; done
tccutil reset Microphone "$BUNDLE" >/dev/null 2>&1 || true
tccutil reset ScreenCapture "$BUNDLE" >/dev/null 2>&1 || true

echo "Reset done. Open Lecture Notes from Applications to test onboarding."
