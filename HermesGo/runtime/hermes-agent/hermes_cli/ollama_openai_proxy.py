"""Small OpenAI-compatible proxy for the bundled Ollama runtime.

The bundled Ollama binary is intentionally old and does not expose /v1.
HermesGo keeps the public local endpoint OpenAI-compatible by translating
the tiny subset used by Hermes Agent: /v1/models and /v1/chat/completions.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.end_headers()
    handler.wfile.write(data)


def _ollama_request(base_url: str, path: str, payload: dict | None = None, timeout: int = 300):
    url = base_url.rstrip("/") + path
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST" if payload is not None else "GET")
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    return urllib.request.urlopen(request, timeout=timeout)


def _extract_model_names(tags_payload: dict) -> list[str]:
    names: list[str] = []
    for model in tags_payload.get("models", []):
        name = model.get("name") or model.get("model")
        if name:
            names.append(str(name))
    return names


def _make_chat_payload(body: dict) -> dict:
    messages = body.get("messages") or []
    return {
        "model": body.get("model") or "gemma:2b",
        "messages": [
            {"role": item.get("role", "user"), "content": item.get("content", "")}
            for item in messages
            if isinstance(item, dict)
        ],
        "stream": bool(body.get("stream", False)),
        "options": {
            "num_predict": int(body.get("max_tokens") or body.get("max_completion_tokens") or 128),
        },
    }


class OllamaOpenAIHandler(BaseHTTPRequestHandler):
    server_version = "HermesGoOllamaOpenAI/1.0"

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/v1/models":
            self._handle_models()
            return
        _json_response(self, 404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        if self.path.rstrip("/") == "/v1/chat/completions":
            self._handle_chat_completions()
            return
        _json_response(self, 404, {"error": {"message": "not found"}})

    def log_message(self, fmt: str, *args) -> None:
        return

    @property
    def ollama_base_url(self) -> str:
        return self.server.ollama_base_url  # type: ignore[attr-defined]

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _handle_models(self) -> None:
        try:
            with _ollama_request(self.ollama_base_url, "/api/tags", timeout=10) as response:
                tags_payload = json.loads(response.read().decode("utf-8"))
            models = [
                {
                    "id": name,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "ollama",
                }
                for name in _extract_model_names(tags_payload)
            ]
            _json_response(self, 200, {"object": "list", "data": models})
        except Exception as exc:
            _json_response(self, 502, {"error": {"message": str(exc)}})

    def _handle_chat_completions(self) -> None:
        try:
            body = self._read_json_body()
            payload = _make_chat_payload(body)
            if payload.get("stream"):
                self._stream_chat(payload)
            else:
                self._plain_chat(payload)
        except Exception as exc:
            _json_response(self, 502, {"error": {"message": str(exc)}})

    def _plain_chat(self, payload: dict) -> None:
        with _ollama_request(self.ollama_base_url, "/api/chat", payload, timeout=300) as response:
            ollama_payload = json.loads(response.read().decode("utf-8"))
        message = ollama_payload.get("message") or {}
        content = message.get("content") or ollama_payload.get("response") or ""
        _json_response(
            self,
            200,
            {
                "id": "chatcmpl-" + uuid.uuid4().hex,
                "object": "chat.completion",
                "created": int(time.time()),
                "model": payload.get("model"),
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }
                ],
            },
        )

    def _stream_chat(self, payload: dict) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        completion_id = "chatcmpl-" + uuid.uuid4().hex
        created = int(time.time())
        with _ollama_request(self.ollama_base_url, "/api/chat", payload, timeout=300) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8").strip()
                if not line:
                    continue
                chunk = json.loads(line)
                message = chunk.get("message") or {}
                content = message.get("content") or ""
                done = bool(chunk.get("done"))
                data = {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": payload.get("model"),
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": content} if content else {},
                            "finish_reason": "stop" if done else None,
                        }
                    ],
                }
                self.wfile.write(("data: " + json.dumps(data, ensure_ascii=False) + "\n\n").encode("utf-8"))
                self.wfile.flush()
                if done:
                    break
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11435)
    parser.add_argument("--ollama", default="http://127.0.0.1:11434")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), OllamaOpenAIHandler)
    server.ollama_base_url = args.ollama  # type: ignore[attr-defined]
    print(f"HermesGo Ollama OpenAI proxy listening on http://{args.host}:{args.port}/v1", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
