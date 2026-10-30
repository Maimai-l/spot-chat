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
  "think"                  -> DeepSeek-style reasoning_content for about a second, then the reply
  "think tags"             -> the thinking inside the reply as <think>...</think>, cut across chunks
  "diagram"                -> a Mermaid flowchart
  a conversation title request -> "Mock title" (not kept as the last request)
  anything else            -> "Echo: <text>" in three chunks
GET /v1/last-request returns the body of the last chat request.

Streams look like DeepSeek's: a keep-alive comment first, a chunk with no choices partway, and, when
stream_options.include_usage is set, a final usage chunk. Its prompt_cache_hit_tokens counts the bytes
the request shares with the start of the previous chat request (a quarter token per byte, in blocks
of 64 tokens), the way a prefix cache would.
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
previous_body = [""]
lock = threading.Lock()


def cache_usage(raw, prompt_text_bytes):
    """Usage for a request whose raw body is `raw`, given the previous chat request's body."""
    with lock:
        previous = previous_body[0]
        previous_body[0] = raw
    shared = 0
    for a, b in zip(previous, raw):
        if a != b:
            break
        shared += 1
    prompt = max(1, prompt_text_bytes // 4)
    hit = min(prompt, (shared // 4) // 64 * 64)
    return {"prompt_cache_hit_tokens": hit, "prompt_cache_miss_tokens": prompt - hit, "prompt_tokens": prompt}


def last_user_parts(body):
    for message in reversed(body.get("messages", [])):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return [{"type": "text", "text": content}]
        return content or []
    return []


DIAGRAM_REPLY = (
    "Here is the flow:\n\n```mermaid\ngraph LR\n  A[Question] --> B{Thinking?}\n"
    "  B -- yes --> C[Reasoning]\n  B -- no --> D[Answer]\n  C --> D\n```\n"
)
THINKING_STEPS = ["The user asks ", "what two plus two is. ", "Adding them ", "gives four. ", "I'll answer briefly."]
TITLE_INSTRUCTION = "Write a title for the conversation below."


def is_title_request(body):
    parts = last_user_parts(body)
    return any(p.get("text", "").startswith(TITLE_INSTRUCTION) for p in parts if p.get("type") == "text")


def reply_chunks(body):
    parts = last_user_parts(body)
    images = [p for p in parts if p.get("type") == "image_url"]
    text = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text")
    if text.startswith(TITLE_INSTRUCTION):
        return ["Mock ", "title"], 0.02
    if images:
        return [f"I can see {len(images)} image(s)."], 0.02
    match = re.search(r"\[File: ([^\]]+)\]", text)
    if match:
        return [f"I read {match.group(1)}."], 0.02
    if text.strip() == "slow":
        return [f"tick {i} " for i in range(60)], 0.2
    if text.strip() == "markdown":
        return [MARKDOWN_REPLY[i:i + 20] for i in range(0, len(MARKDOWN_REPLY), 20)], 0.02
    if text.strip() == "think tags":
        return ["<thi", "nk>The user asks ", "for a sum.</th", "ink>\n\n", "Two plus two ", "is four."], 0.05
    if text.strip() == "diagram":
        return [DIAGRAM_REPLY[i:i + 20] for i in range(0, len(DIAGRAM_REPLY), 20)], 0.02
    if text.strip() == "think":
        thinking = [("reasoning", part) for part in THINKING_STEPS]
        return thinking + ["Two plus two ", "is four."], 0.15
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
        raw = self.rfile.read(length) or b"{}"
        body = json.loads(raw)
        if not self.path.endswith("/chat/completions"):
            self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})
            return
        if not is_title_request(body):
            with lock:
                last_request.clear()
                last_request.update(body)
        if not self.authorized():
            return
        if "fail" in "\n".join(p.get("text", "") for p in last_user_parts(body)).split():
            self.send_json(500, {"error": {"message": "The server had an error.", "type": "server_error"}})
            return

        chunks, delay = reply_chunks(body)
        usage = None
        if (body.get("stream_options") or {}).get("include_usage"):
            usage = {"prompt_tokens": 0, "completion_tokens": 0}
            if not is_title_request(body):
                usage.update(cache_usage(raw.decode("utf-8", "replace"), len(json.dumps(body.get("messages", [])))))
            usage["completion_tokens"] = sum(len(c if isinstance(c, str) else c[1]) for c in chunks) // 4
            usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        model = body.get("model", "mock-fast")
        try:
            self.wfile.write(b": keep-alive\n\n")
            self.wfile.flush()
            for index, chunk in enumerate(chunks):
                # A ("reasoning", text) pair is sent the way DeepSeek sends its thinking.
                delta = {"reasoning_content": chunk[1]} if isinstance(chunk, tuple) else {"content": chunk}
                if index == 0:
                    delta["role"] = "assistant"
                self.write_event({
                    "id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": 0, "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                })
                time.sleep(delay)
                if index == 0:
                    self.write_event({"choices": []})
            self.write_event({
                "id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": 0, "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            })
            if usage:
                self.write_event({"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": 0,
                                  "model": model, "choices": [], "usage": usage})
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
