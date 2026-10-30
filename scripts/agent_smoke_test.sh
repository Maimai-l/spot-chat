#!/bin/bash
# Runs the bundled dsh runtime over ACP against a stand-in for DeepSeek's Messages API and checks
# that a write inside the session folder runs, a write outside it is stopped by the sandbox, and the
# retry asks for approval: allowed once it writes, rejected it doesn't.
# Usage: agent_smoke_test.sh <runtime folder from build_agent_runtime.py>
set -euo pipefail
runtime="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT
# The outside folder must not be under a temporary root, which workspace-write leaves writable.
outside="$HOME/.spot-chat-agent-test-$$"
mkdir -p "$work/home/profiles" "$work/session" "$outside"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work" "$outside"' EXIT
cp -R "$runtime/profile" "$work/home/profiles/spot"

status=0
port=18930
for decision in allow reject; do
  rm -f "$outside/escape.txt" "$work/session/inside.txt"
  python3 -I "$here/agent_test/mock_messages.py" $port "$work/requests-$decision.log" \
    "echo in > '$work/session/inside.txt'; echo out > '$outside/escape.txt'" &
  sleep 1
  DSH_HOME="$work/home" DSH_BIN="$runtime/dsh" DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="http://127.0.0.1:$port" \
    "$runtime/node" "$here/agent_test/acp_client.mjs" "$work/acp-$decision.log" "$work/session" "Write the files" $decision
  kill %1 2>/dev/null || true
  wait 2>/dev/null || true
  port=$((port + 1))

  asked=$(grep -c '"session/request_permission"' "$work/acp-$decision.log" || true)
  denied=$(grep -c 'sandbox: file access denied' "$work/acp-$decision.log" || true)
  [ -f "$work/session/inside.txt" ] && inside=yes || inside=no
  [ -f "$outside/escape.txt" ] && escaped=yes || escaped=no
  echo "$decision: inside=$inside sandbox-denied=$denied approval-asked=$asked outside=$escaped"
  want_out=$([ $decision = allow ] && echo yes || echo no)
  if [ "$inside" != yes ] || [ "$denied" -lt 1 ] || [ "$asked" -lt 1 ] || [ "$escaped" != "$want_out" ]; then
    echo "  FAILED; ACP log:"; cut -c1-400 "$work/acp-$decision.log"; cat "$work/acp-$decision.log.stderr" 2>/dev/null | tail -20
    status=1
  fi
done

tools=$(python3 -c "import json,sys; print(' '.join(sorted(t['name'] for t in json.loads(open(sys.argv[1]).readline())['body']['tools'])))" "$work/requests-allow.log")
echo "tools: $tools"
[ "$tools" = "bash read_image web_fetch web_search working_directory" ] || { echo "  FAILED: unexpected tools"; status=1; }
exit $status
