#!/bin/bash
# Builds for the simulator from a copy outside iCloud Drive: in ~/Documents, xcodebuild
# can hang forever on a file-coordination claim held by iCloud.
set -euo pipefail
W="$HOME/Library/Caches/otto-design"
rsync -a --delete --exclude build --exclude build.nosync --exclude .git "$(dirname "$0")/../" "$W/src/"
cd "$W/src" && xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug \
  -destination "platform=iOS Simulator,id=${DEV:-1A22C70F-011C-4D46-8DD0-E6F23E432780}" \
  -derivedDataPath "$W/dd" -disableAutomaticPackageResolution -skipMacroValidation build -quiet
