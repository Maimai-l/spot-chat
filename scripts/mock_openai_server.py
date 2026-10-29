#!/usr/bin/env python3
"""A small OpenAI-compatible server for tests.

Usage: mock_openai_server.py [port]

Requests must send "Authorization: Bearer test-key".
The reply depends on the last user message:
  contains an image        -> "I can see N image(s)."
  contains "[File: name]"  -> "I read name."
  "slow"                   -> 60 chunks, 0.2 s apart
  "fail"                   -> HTTP 500 with an error message
  "markdown"               -> a heading, a list, a code block and a table
  "math"                   -> inline and display LaTeX next to prices
  anything else            -> "Echo: <text>" in three chunks
GET /v1/last-request returns the body of the last chat request.
"""

import json
import re
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = "test-key"
MODELS = ["mock-fast", "mock-vision"]
MARKDOWN_REPLY = (
    "**注意：**注意：这里是加粗，**Bold** Bold，`inline code` 也在这一行。\n"
    "模型的第二行紧接着换行。\n\n"
    "## Steps\n\n"
    "- **First** item\n"
    "- Second item\n\n"
    "```sql\nPRAGMA journal_mode = WAL;\n```\n\n"
    "| Mode | Readers |\n| --- | --- |\n| DELETE | blocked |\n| WAL | concurrent |\n"
)

MATH_REPLY = (
    "The area of a circle is \\(A = \\pi r^2\\), and it costs $5 or $10 to print.\n\n"
    "\\[\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n\\]\n\n"
    "With dollars: $e^{i\\pi} + 1 = 0$ and $$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$$\n"
)

last_request = {}
lock = threading.Lock()


def last_user_parts(body):
    for message in reversed(body.get("messages", [])):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return [{"type": "text", "text": content}]
        return content or []
    return []


def reply_chunks(body):
    parts = last_user_parts(body)
    images = [p for p in parts if p.get("type") == "image_url"]
    text = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text")
    if images:
        return [f"I can see {len(images)} image(s)."], 0.02
    match = re.search(r"\[File: ([^\]]+)\]", text)
    if match:
        return [f"I read {match.group(1)}."], 0.02
    if text.strip() == "slow":
        return [f"tick {i} " for i in range(60)], 0.2
    if text.strip() == "markdown":
        return [MARKDOWN_REPLY[i:i + 20] for i in range(0, len(MARKDOWN_REPLY), 20)], 0.02
    if text.strip() == "math":
        return [MATH_REPLY[i:i + 20] for i in range(0, len(MATH_REPLY), 20)], 0.02
    reply = f"Echo: {text}"
    third = max(1, len(reply) // 3)
    return [reply[:third], reply[third:2 * third], reply[2 * third:]], 0.05


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, format, *args):
        sys.stderr.write("mock: " + format % args + "\n")

    def send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {API_KEY}":
            return True
        self.send_json(401, {"error": {
            "message": "Incorrect API key provided.",
            "type": "invalid_request_error", "param": None, "code": "invalid_api_key",
        }})
        return False

    def do_GET(self):
        if self.path.endswith("/last-request"):
            with lock:
                self.send_json(200, last_request)
            return
        if not self.authorized():
            return
        if self.path.endswith("/models"):
            self.send_json(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": 0, "owned_by": "mock"} for m in MODELS
            ]})
            return
        self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.endswith("/chat/completions"):
            self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})
            return
        with lock:
            last_request.clear()
            last_request.update(body)
        if not self.authorized():
            return
        if "fail" in "\n".join(p.get("text", "") for p in last_user_parts(body)).split():
            self.send_json(500, {"error": {"message": "The server had an error.", "type": "server_error"}})
            return

        chunks, delay = reply_chunks(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        model = body.get("model", "mock-fast")
        try:
            for index, chunk in enumerate(chunks):
                delta = {"content": chunk}
                if index == 0:
                    delta["role"] = "assistant"
                self.write_event({
                    "id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": 0, "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                })
                time.sleep(delay)
            self.write_event({
                "id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": 0, "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            })
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def write_event(self, payload):
        self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
        self.wfile.flush()


class LoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer looks up the host name here, which on macOS asks for local network access
        # and puts a permission prompt over the app under test.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    LoopbackServer(("127.0.0.1", port), Handler).serve_forever()
