#!/usr/bin/env bash
# Starts a DeepSeek Harness for the UI test that runs commands there: `dsh web` from the channel
# agent/package.json names, with Spot Chat's plugin, its model the mock server on port $1. The plugin's
# socket is in /tmp/spot-chat-harness; dsh keeps its sessions and log in /tmp/spot-chat-harness-dsh.
set -euo pipefail
port="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
channel="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["dependencies"]["@deepseek-ai/dsh"])' "$root/agent/package.json")"
work=/tmp/spot-chat-harness-dsh
export SPOT_CHAT_BRIDGE_DIR=/tmp/spot-chat-harness DSH_HOME="$work/home"
rm -rf "$work" "$SPOT_CHAT_BRIDGE_DIR"
mkdir -p "$work"
cd "$work"
npm init -y >/dev/null
npm install --no-audit --no-fund --ignore-scripts "@deepseek-ai/dsh@$channel" >/dev/null
node_modules/.bin/dsh plugin --profile web add "file:$root/agent/bridge" >/dev/null
DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="http://127.0.0.1:$port" DO_NOT_TRACK=1 \
  nohup node_modules/.bin/dsh web --no-open --port 0 > "$work/web.log" 2>&1 &
for _ in $(seq 1 90); do [ -S "$SPOT_CHAT_BRIDGE_DIR/bridge.sock" ] && break; sleep 1; done
[ -S "$SPOT_CHAT_BRIDGE_DIR/bridge.sock" ] || { echo "The plugin's socket never appeared"; cat "$work/web.log"; exit 1; }
echo "DeepSeek Harness $(node -p 'require("./node_modules/@deepseek-ai/dsh/package.json").version') is running with Spot Chat's plugin"
