#!/usr/bin/env bash
# Checks Spot Chat's bridge into a dsh the user runs: installs dsh from the channel agent/package.json
# names, adds the bridge to its web profile, starts `dsh web` against the mock model, and connects as Spot
# Chat does. A wrong token is refused, two connections work at once, a command runs in the folder, one
# outside the folder asks the client first, and a session is shared with the dsh it runs in.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
channel="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["dependencies"]["@deepseek-ai/dsh"])' "$root/agent/package.json")"
work="$(mktemp -d)"
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -f "$work/web.log" ]; then
    echo "dsh web's log:"
    tail -60 "$work/web.log"
  fi
  # dsh first, then its files, so it doesn't reload a profile that is being deleted.
  [ -n "${web:-}" ] && { kill "$web" 2>/dev/null; wait "$web" 2>/dev/null; } || true
  [ -n "${mock:-}" ] && kill "$mock" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cd "$work"
npm init -y >/dev/null
npm install --no-audit --no-fund --ignore-scripts "@deepseek-ai/dsh@$channel" >/dev/null
version="$(node -p 'require("./node_modules/@deepseek-ai/dsh/package.json").version')"
echo "dsh $version from the $channel channel"

export DSH_HOME="$work/home" SPOT_CHAT_BRIDGE_DIR="$work/bridge"
node_modules/.bin/dsh plugin --profile web add "file:$root/agent/bridge" >/dev/null
mkdir -p "$SPOT_CHAT_BRIDGE_DIR" "$work/folder"
chmod 700 "$SPOT_CHAT_BRIDGE_DIR"
token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$token" > "$SPOT_CHAT_BRIDGE_DIR/token.sha256"

port=8790
python3 "$root/scripts/mock_openai_server.py" "$port" > "$work/mock.log" 2>&1 &
mock=$!
DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="http://127.0.0.1:$port" DO_NOT_TRACK=1 \
  node_modules/.bin/dsh web --no-open --port 0 > "$work/web.log" 2>&1 &
web=$!
socket="$SPOT_CHAT_BRIDGE_DIR/bridge.sock"
for _ in $(seq 1 90); do [ -S "$socket" ] && break; sleep 1; done
[ -S "$socket" ] || { echo "The bridge's socket never appeared"; cat "$work/web.log"; exit 1; }
# The plugin makes the socket private just after it binds; its folder is private before that.
mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
[ "$(mode "$SPOT_CHAT_BRIDGE_DIR")" = "0o700" ] || { echo "The bridge's folder isn't private"; exit 1; }
for _ in $(seq 1 50); do [ "$(mode "$socket")" = "0o600" ] && break; sleep 0.1; done
[ "$(mode "$socket")" = "0o600" ] || { echo "The socket isn't private: $(mode "$socket")"; exit 1; }

client="$here/agent_test/bridge_client.mjs"
wrong="$(node "$client" "$socket" not-the-token "$work/folder" hello wrong)"
node "$client" "$socket" "$token" "$work/folder" "hello" chat > "$work/chat.json" &
chat_pid=$!
node "$client" "$socket" "$token" "$work/folder" "Please list the files" list > "$work/list.json"
wait "$chat_pid" || true
chat="$(cat "$work/chat.json")"
list="$(cat "$work/list.json")"
outside="$(node "$client" "$socket" "$token" "$work/folder" "Write outside the folder" outside)"
sharing="$(node "$here/agent_test/bridge_sharing.mjs" "$socket" "$token" "$work/folder" || true)"
# Every request here comes from a session of Spot Chat's.
session_logs="$(curl -s "http://127.0.0.1:$port/session-logs")"
sessions_mode="$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$SPOT_CHAT_BRIDGE_DIR/sessions" 2>/dev/null || echo none)"

python3 - "$wrong" "$chat" "$list" "$outside" "$version" "${sharing:-{\}}" "$session_logs" "$sessions_mode" <<'PY'
import json, os, sys
wrong, chat, listed, outside = (json.loads(a) for a in sys.argv[1:5])
sharing = json.loads(sys.argv[6])
session_logs = json.loads(sys.argv[7] or "[]")
checks = [
    ("A wrong token is refused", not wrong["admitted"]),
    ("A question gets its answer", chat["admitted"] and chat["text"] == "Hello from dsh."),
    ("A second connection at the same time runs a command in the folder",
     any(t.endswith(":ls -a") for t in listed["tools"]) and any(o.startswith("completed:") for o in listed["outputs"])),
    # The mock asks again with escalation only when the sandbox stopped the first try.
    ("A command outside the folder asks the client first",
     outside["approvals"] >= 1 and len(outside["tools"]) == 2 and outside["outputs"][-1].startswith("completed:")),
    # A second connection stands in for dsh's own interface.
    ("dsh's side joins a session Spot Chat holds, and runs a command Spot Chat sees",
     sharing.get("joinedWhileHeld") and sharing.get("otherSideRan") and sharing.get("spotSawIt")),
    ("A turn goes on after Spot Chat leaves", sharing.get("turnWentOn")),
    ("Spot Chat comes back to the session and goes on with it", sharing.get("cameBack")),
    ("Stopping still stops", sharing.get("stopStops")),
    ("Spot Chat sees a question asked on dsh's side, before what was done for it", sharing.get("spotSawTheQuestion")),
    ("The history has every question, the commands and how each turn ended",
     sharing.get("historyHasEveryQuestion") and sharing.get("historyHasCommands") and sharing.get("historyHasEnds")),
    # dsh's own sessions still carry it; that was checked by hand in dsh web's window.
    ("Requests from Spot Chat's sessions leave dsh's session log out",
     len(session_logs) > 0 and not any(request["sessionLog"] for request in session_logs)),
    ("The list of Spot Chat's sessions is private", sys.argv[8] == "0o600"),
]
lines = [f"{'pass' if ok else 'FAIL'}: {name}" for name, ok in checks]
print("\n".join(lines))
for result in (wrong, chat, listed, outside, sharing):
    print(json.dumps(result))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as f:
        f.write(f"## Forwarding to your dsh\n\ndsh {sys.argv[5]}\n\n" + "\n".join(f"- {l}" for l in lines) + "\n")
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
