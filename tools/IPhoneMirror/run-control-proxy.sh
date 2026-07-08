#!/usr/bin/env bash
set -euo pipefail

command -v iproxy >/dev/null || {
  echo "iproxy not found. Install with: brew install libimobiledevice"
  exit 1
}

echo "Forwarding localhost:8100 to iPhone WebDriverAgent:8100"
iproxy 8100 8100
