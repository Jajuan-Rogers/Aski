#!/usr/bin/env python3
"""Tiny OpenAI-compatible server used by the Aski test suite."""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUEST_PATH = os.environ.get("ASKI_TEST_REQUEST", "/tmp/aski-last-request.json")


def build_echo(data):
    user = ""
    for message in data.get("messages") or []:
        if message.get("role") == "user":
            user = message.get("content") or ""
    if "\n\nQuestion:\n" in user:
        context, question = user.split("\n\nQuestion:\n", 1)
    else:
        context, question = user, ""
    if context.startswith("Context:\n"):
        context = context[len("Context:\n") :]
    stripped = context.strip()
    lines = stripped.splitlines() if stripped else []
    first = lines[0] if lines else "(empty)"
    return (
        f"You asked: {question.strip()}\n\n"
        f"The selection starts with `{first}` and is {len(lines)} lines."
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _body(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        meta = {
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "expect": self.headers.get("Expect", ""),
        }
        with open(REQUEST_PATH, "w", encoding="utf-8") as handle:
            handle.write(raw.decode("utf-8"))
        with open(REQUEST_PATH + ".meta", "w", encoding="utf-8") as handle:
            json.dump(meta, handle)
        return json.loads(raw.decode("utf-8") or "{}")

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _sse(self, parts, delay):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            for index, part in enumerate(parts):
                payload = json.dumps({"choices": [{"delta": {"content": part}}]})
                self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                self.wfile.flush()
                if delay and index < len(parts) - 1:
                    time.sleep(delay)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_GET(self):
        self._json(200, {"ok": True})

    def do_POST(self):
        try:
            data = self._body()
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "invalid json"}})
            return
        model = data.get("model")
        if model == "error-model":
            self._json(401, {"error": {"message": "bad key"}})
            return
        if model == "plain-model":
            self._json(200, {"choices": [{"message": {"content": "plain reply"}}]})
            return
        if model == "slow-model":
            time.sleep(0.8)
            self._sse(["too late"], 0)
            return
        if model == "echo-model":
            text = build_echo(data)
            parts = [text[i : i + 24] for i in range(0, len(text), 24)] or [""]
            self._sse(parts, 0.03)
            return
        self._sse(["Hello ", "from ", "Aski.\n", "Second line."], 0.08)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
