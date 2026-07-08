#!/usr/bin/env bash
set -euo pipefail

screen -S IPhoneMirrorWDA -X quit 2>/dev/null || true
screen -S IPhoneMirrorProxy -X quit 2>/dev/null || true
pkill -f '/opt/homebrew/bin/iproxy 8100:8100' 2>/dev/null || true
pkill -f 'WebDriverAgentRunner' 2>/dev/null || true
pkill -f 'run-wda.sh' 2>/dev/null || true
echo "Stopped IPhoneMirror control sessions."
