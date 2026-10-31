#!/usr/bin/env python3
"""A small OpenAI-compatible server for tests.

Usage: mock_openai_server.py [port]

Requests must send "Authorization: Bearer test-key".
The reply depends on the last user message:
  contains an image        -> "I can see N image(s)."
  contains "[File: name]"  -> "I read name."
  "slow"                   -> 60 chunks, 0.2 s apart
  "wait"                   -> nothing for 3 s, then "Echo: wait"
  "fail"                   -> HTTP 500 with an error message
  "markdown"               -> a heading, a list, a code block and a table
  "math"                   -> inline and display LaTeX next to prices
  "think"                  -> DeepSeek-style reasoning_content for about a second, then the reply
  "think tags"             -> the thinking inside the reply as <think>...</think>, cut across chunks
  "diagram"                -> a Mermaid flowchart
  a conversation title request -> "Mock title" (not kept as the last request)
mock-vision has no reasoning: a request with reasoning_effort gets OpenAI's 400 for it.
  anything else            -> "Echo: <text>" in three chunks
GET /v1/last-request returns the body of the last chat request.

Streams look like DeepSeek's: a keep-alive comment first, a chunk with no choices partway, and, when
stream_options.include_usage is set, a final usage chunk. Its prompt_cache_hit_tokens counts the bytes
the request shares with the start of the previous chat request (a quarter token per byte, in blocks
of 16 tokens), the way a prefix cache would.
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
    # DeepSeek caches in larger blocks; small ones let short test conversations show a hit.
    hit = min(prompt, (shared // 4) // 16 * 16)
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


# Stand-in for DeepSeek's Anthropic-format Messages API, which dsh uses to run commands.
# The question picks the script: "outside" writes outside the folder (stopped by the sandbox, then asked
# for), "slow" runs a long command, "list" runs a short one; anything else gets a plain answer.
ESCAPE = 'echo out > "$HOME/.spot-chat-ui-test-escape" && rm "$HOME/.spot-chat-ui-test-escape"'
last_messages_request = {}


def messages_steps(body):
    """The next tool call as (description, command, escalate), or the final text."""
    texts, results = [], []
    for message in body.get("messages", []):
        content = message.get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        blocks = content or []
        # A user message with text starts a new question; only its own tool results count.
        asked = [b.get("text", "") for b in blocks if message.get("role") == "user" and b.get("type") == "text"
                 and not b.get("text", "").startswith("Current runtime context")]
        if asked:
            texts, results = asked, []
        results += [json.dumps(b) for b in blocks if b.get("type") == "tool_result"]
    question = " ".join(t for t in texts if not t.startswith("Current runtime context"))
    if "outside" in question:
        if not results:
            return ("Write a note in your home folder", ESCAPE, False)
        if len(results) == 1 and "sandbox" in results[0]:
            return ("Write a note in your home folder", ESCAPE, True)
        return "Finished."
    if "slow" in question:
        return ("Wait a minute", "sleep 60", False) if not results else "Stopped."
    if "search" in question:
        if not results:
            return ("web_search", {"queries": ["DaVinci Resolve MCP server"]})
        if len(results) == 1:
            return ("web_fetch", {"url": "https://example.com/resolve-mcp"})
        return "Here is what I found."
    if "list" in question:
        return ("List the folder", "ls -a", False) if not results else "Listed the folder."
    return "Hello from dsh."


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
        if self.path.endswith("/last-messages-request"):
            with lock:
                self.send_json(200, last_messages_request)
            return
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
        if self.path.endswith("/v1/messages"):
            self.messages(body)
            return
        # DeepSeek's Search and Fetch API, which dsh's web tools use.
        if self.path.endswith("/tools/search"):
            self.send_json(200, {"results": [
                {"title": "samuelgursky/davinci-resolve-mcp", "url": "https://github.com/samuelgursky/davinci-resolve-mcp",
                 "snippet": "An MCP server for DaVinci Resolve.", "summary": "An MCP server for DaVinci Resolve.", "date": None},
                {"title": "DaVinci Resolve MCP Server", "url": "https://www.flowhunt.io/mcp-servers/davinci-resolve/",
                 "snippet": "Connect AI assistants to Resolve.", "summary": "Connect AI assistants to Resolve.", "date": "2026-09-01"},
            ]})
            return
        if self.path.endswith("/tools/fetch"):
            self.send_json(200, {"content": "# Resolve MCP\n\nControl DaVinci Resolve from an assistant.\n"})
            return
        if not self.path.endswith("/chat/completions"):
            self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})
            return
        if not is_title_request(body):
            with lock:
                last_request.clear()
                last_request.update(body)
        if not self.authorized():
            return
        if body.get("model") == "mock-vision" and "reasoning_effort" in body:
            self.send_json(400, {"error": {
                "message": "Unsupported parameter: 'reasoning_effort' is not supported with this model.",
                "type": "invalid_request_error", "param": "reasoning_effort", "code": "unsupported_parameter",
            }})
            return
        if "fail" in "\n".join(p.get("text", "") for p in last_user_parts(body)).split():
            self.send_json(500, {"error": {"message": "The server had an error.", "type": "server_error"}})
            return

        # With tools offered, a question about searching makes the model search, then read a page.
        if body.get("tools") and not is_title_request(body):
            question = "\n".join(p.get("text", "") for p in last_user_parts(body))
            results = [m for m in body.get("messages", []) if m.get("role") == "tool"]
            if "search" in question and len(results) == 0:
                self.stream_tool_call("web_search", {"queries": ["DaVinci Resolve MCP server"]})
                return
            if "search" in question and len(results) == 1:
                self.stream_tool_call("web_fetch", {"url": "https://example.com/resolve-mcp"})
                return
            if "search" in question:
                self.stream_text("Here is what I found.")
                return

        chunks, delay = reply_chunks(body)
        usage = None
        if (body.get("stream_options") or {}).get("include_usage"):
            usage = {"prompt_tokens": 0, "completion_tokens": 0}
            if not is_title_request(body):
                messages_text = json.dumps(body.get("messages", []), ensure_ascii=False, separators=(",", ":"))
                usage.update(cache_usage(raw.decode("utf-8", "replace"), len(messages_text)))
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
            question = "\n".join(p.get("text", "") for p in last_user_parts(body) if p.get("type") == "text")
            if question.strip() == "wait":
                time.sleep(3)
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

    def stream_tool_call(self, name, arguments):
        """A tool call split over several chunks, as DeepSeek streams it: the id and name first, later
        pieces with an empty id, then the arguments in parts."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        call_id = f"call_{name}"
        text = json.dumps(arguments)
        half = len(text) // 2
        pieces = [
            {"index": 0, "id": call_id, "type": "function", "function": {"name": name, "arguments": ""}},
            {"index": 0, "id": "", "function": {"arguments": text[:half]}},
            {"index": 0, "function": {"arguments": text[half:]}},
        ]
        try:
            for piece in pieces:
                self.write_event({"choices": [{"index": 0, "delta": {"tool_calls": [piece]}, "finish_reason": None}]})
            self.write_event({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def stream_text(self, text):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            self.write_event({"choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]})
            self.write_event({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def messages(self, body):
        with lock:
            last_messages_request.clear()
            last_messages_request.update({k: v for k, v in body.items() if k in ("model", "thinking", "output_config")})
        step = messages_steps(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        try:
            event("message_start", {"type": "message_start", "message": {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": body.get("model"), "content": [],
                "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}})
            if isinstance(step, str):
                event("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
                event("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": step}})
                stop = "end_turn"
            else:
                if len(step) == 2:
                    name, tool_input = step
                else:
                    name = "bash"
                    description, command, escalate = step
                    tool_input = {"description": description, "command": command}
                    if escalate:
                        tool_input.update({"sandbox_permissions": "danger-full-access",
                                           "justification": "The note goes in your home folder, outside this one."})
                calls = sum(1 for m in body.get("messages", []) if m.get("role") == "assistant")
                event("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
                    "type": "tool_use", "id": f"toolu_{calls + 1}", "name": name, "input": {}}})
                event("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
                    "type": "input_json_delta", "partial_json": json.dumps(tool_input)}})
                stop = "tool_use"
            event("content_block_stop", {"type": "content_block_stop", "index": 0})
            event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                    "usage": {"output_tokens": 5}})
            event("message_stop", {"type": "message_stop"})
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
