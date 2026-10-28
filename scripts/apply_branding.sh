#!/bin/bash
# Sets the phone app name to "Beauty Souq" and installs the Beauty Souq icon.
# Run once from the project folder:   ./scripts/apply_branding.sh
set -e
cd "$(dirname "$0")/.."
NAME="Beauty Souq"

echo "▶ Installing the icon generator…"
flutter pub add dev:flutter_launcher_icons

echo "▶ Generating app icons (Android + iOS)…"
dart run flutter_launcher_icons

MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ]; then
  perl -pi -e "s/android:label=\"[^\"]*\"/android:label=\"$NAME\"/" "$MANIFEST"
  echo "✓ Android app name set to $NAME"
else
  echo "! $MANIFEST not found (run: flutter create --platforms=android,ios .)"
fi

PLIST="ios/Runner/Info.plist"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$PLIST" 2>/dev/null || true
  echo "✓ iOS app name set to $NAME"
fi

echo "✓ Done. Rebuild the app (flutter run / build apk) to see the new name and icon."
