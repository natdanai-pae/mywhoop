#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project IPhoneMirror.xcodeproj -scheme IPhoneMirror -configuration Debug -destination 'platform=macOS' build
APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/IPhoneMirror.app' -print -quit)"
open "$APP_PATH"
