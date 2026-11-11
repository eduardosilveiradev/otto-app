#!/bin/bash
# Builds the throwaway harness from the worktree's real sources. Harness-only patches, on a copy:
# the keyboard's model is reachable, and Full Access counts as on (an app can't grant it).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); R=${1:?worktree}
rm -rf "$H/src" "$H/Harness.app"; mkdir -p "$H/src" "$H/Harness.app"
cp "$R"/OttoKeyboard/*.swift "$H/src/"
sed -i '' -e 's/private let model = BoardModel()/let model = BoardModel()/' -e 's/guard hasFullAccess else/guard true else/' -e 's/self?\.textDocumentProxy\.documentIdentifier/harnessDocID/g' -e 's/textDocumentProxy\.documentIdentifier/harnessDocID/g' "$H/src/KeyboardViewController.swift"
cp "$R"/OttoKeyboard/words-*.txt "$H/Harness.app/"
cat > "$H/ent.xcent" <<X
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>application-identifier</key><string>FAKETEAM00.dev.example.harness</string>
<key>keychain-access-groups</key><array><string>FAKETEAM00.dev.example.harness</string></array></dict></plist>
X
cat > "$H/Harness.app/Info.plist" <<X
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.example.harness</string><key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundleName</key><string>Harness</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>26.0</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer></array><key>LSRequiresIPhoneOS</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
X
derq query -f xml -i "$H/ent.xcent" -o "$H/ent.der" --raw
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -sdk "$SDK" -swift-version 5 -parse-as-library -D DEBUG -Onone \
  "$H"/src/*.swift "$R"/Shared/*.swift "$R"/OttoShare/ShareViewController.swift "$H/Harness.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$H/ent.xcent" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$H/ent.der" \
  -o "$H/Harness.app/Harness"
# Like Xcode for the simulator: ad-hoc, entitlements only in the sections above.
codesign -f -s - "$H/Harness.app"
echo built
