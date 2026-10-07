#!/bin/bash
# Builds an unsigned IPA and publishes it to the Otto server on this Mac, which
# offers it to the app (GET /app/update) and to SideStore as a source
# (/app/release/<key>/source.json). SideStore re-signs it on the phone.
#
# The build number is the build time, so every release is newer than the last.
#
# Usage: Scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OTTO_RELEASE_DIR:-$HOME/.otto/state/app-release}"
BUILD="$(date +%Y%m%d%H%M)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building $BUILD…"
xcodebuild -project "$ROOT/Otto.xcodeproj" -scheme Otto -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD" build -quiet

APP="$WORK/dd/Build/Products/Release-iphoneos/Otto.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")"
mkdir -p "$WORK/ipa/Payload" "$OUT"
cp -R "$APP" "$WORK/ipa/Payload/"
(cd "$WORK/ipa" && zip -qry Otto.ipa Payload)

# The download link has no login (SideStore can't send one), so it carries an
# unguessable key instead. Made once; delete the file to rotate it.
[ -s "$OUT/key" ] || (umask 077; openssl rand -hex 16 > "$OUT/key")

# Copy, then rename: the server may be serving the old one right now.
cp "$WORK/ipa/Otto.ipa" "$OUT/Otto.ipa.tmp" && mv "$OUT/Otto.ipa.tmp" "$OUT/Otto.ipa"
cp "$WORK/ipa/Otto.ipa" "$ROOT/build/Otto.ipa" 2>/dev/null || true
printf '{"version":"%s","build":"%s","date":"%s","size":%s}\n' \
  "$VERSION" "$BUILD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(stat -f%z "$OUT/Otto.ipa")" > "$OUT/release.json"

echo "==> Published $VERSION ($BUILD) to $OUT"
