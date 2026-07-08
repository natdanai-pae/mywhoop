#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${1:-00008150-000251E9349A401C}"
TEAM_ID="${TEAM_ID:-YG7X8EC59V}"
WDA_PROJECT="/Users/maripae/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj"

if [[ ! -d "$WDA_PROJECT" ]]; then
  echo "WebDriverAgent not found. Run:"
  echo "  npm install -g appium"
  echo "  /Users/maripae/.hermes/node/bin/appium driver install xcuitest"
  exit 1
fi

xcodebuild \
  -project "$WDA_PROJECT" \
  -scheme WebDriverAgentRunner \
  -destination "id=$DEVICE_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  test
