#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${1:-00008150-000251E9349A401C}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

screen -S IPhoneMirrorWDA -X quit 2>/dev/null || true
screen -S IPhoneMirrorProxy -X quit 2>/dev/null || true
pkill -f '/opt/homebrew/bin/iproxy 8100:8100' 2>/dev/null || true
pkill -f 'WebDriverAgentRunner' 2>/dev/null || true
pkill -f 'run-wda.sh' 2>/dev/null || true

: > "$ROOT_DIR/wda.log"
: > "$ROOT_DIR/iproxy.log"

screen -dmS IPhoneMirrorWDA zsh -lc "cd '$ROOT_DIR'; ./run-wda.sh '$DEVICE_ID' > wda.log 2>&1"

echo "Starting WebDriverAgent..."
for _ in {1..30}; do
  if grep -q 'ServerURLHere' "$ROOT_DIR/wda.log" 2>/dev/null; then
    break
  fi
  sleep 1
done

screen -dmS IPhoneMirrorProxy zsh -lc "/opt/homebrew/bin/iproxy 8100:8100 -u '$DEVICE_ID' > '$ROOT_DIR/iproxy.log' 2>&1"

echo "Waiting for localhost:8100..."
for _ in {1..20}; do
  if curl -fsS --max-time 2 http://127.0.0.1:8100/status >/dev/null 2>&1; then
    echo "Control ready. Open IPhoneMirror and press Control On."
    exit 0
  fi
  sleep 1
done

echo "Control did not become ready. Check:"
echo "  tail -80 '$ROOT_DIR/wda.log'"
echo "  tail -40 '$ROOT_DIR/iproxy.log'"
exit 1
