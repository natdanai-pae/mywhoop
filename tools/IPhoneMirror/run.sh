#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
xcodegen generate
xcodebuild \
  -project IPhoneMirror.xcodeproj \
  -scheme IPhoneMirror \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build
APP_PATH="$PWD/build/DerivedData/Build/Products/Debug/IPhoneMirror.app"
killall IPhoneMirror 2>/dev/null || true
open "$APP_PATH"
