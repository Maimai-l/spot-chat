"""A DeepSeek Messages (Anthropic-format) stand-in: asks for one bash command, then says Done."""
import json, sys, socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]
COMMAND = sys.argv[3]

class Server(ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]

def event(w, name, data):
    w.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode()); w.flush()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items() if k.lower() != "x-api-key"}, "body": body}) + "\n")
        msgs = body.get("messages", [])
        results = [b for m in msgs if isinstance(m.get("content"), list) for b in m["content"] if b.get("type") == "tool_result"]
        last = json.dumps(results[-1]) if results else ""
        retry = len(results) == 1 and ("sandbox" in last or "denied" in last)
        has_result = bool(results) and not retry
        tools = [t.get("name") for t in body.get("tools", [])]
        bash = next((t for t in tools if "bash" in (t or "")), tools[0] if tools else "bash")
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        w = self.wfile
        event(w, "message_start", {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": body.get("model"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}})
        if has_result:
            event(w, "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            event(w, "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Done."}})
            event(w, "content_block_stop", {"type": "content_block_stop", "index": 0})
            event(w, "message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 2}})
        else:
            event(w, "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": f"toolu_{len(results) + 1}", "name": bash, "input": {}}})
            event(w, "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps({"description": "Write test files", "command": COMMAND, **({"sandbox_permissions": "danger-full-access", "justification": "The file goes in a folder outside the workspace."} if retry else {})})}})
            event(w, "content_block_stop", {"type": "content_block_stop", "index": 0})
            event(w, "message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 5}})
        event(w, "message_stop", {"type": "message_stop"})

Server(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
