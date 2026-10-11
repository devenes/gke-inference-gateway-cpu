#!/usr/bin/env python3
"""Lightweight HTTP server for rule-based automatic model routing on GKE.

Exposes:
- GET  /health               -> HTTP 200 {"status": "ok"}
- POST /v1/chat/completions  -> Validates & classifies request, injects selected
                                'model' field, and forwards to internal ClusterIP
                                model service with full SSE streaming support.
"""

from __future__ import annotations

import datetime
import http.client
import http.server
import json
import os
import socket
import sys
import time
import urllib.parse
import uuid
from typing import Dict, Optional, Tuple

try:
    from router.classifier import (
        COMPLEX_MODEL,
        SIMPLE_MODEL,
        RequestValidationError,
        RouterConfig,
         evaluate_chat_request,
    )
except ImportError:
    from classifier import (  # type: ignore
        COMPLEX_MODEL,
        SIMPLE_MODEL,
        RequestValidationError,
        RouterConfig,
        evaluate_chat_request,
    )


def log_json(event: Dict[str, object]) -> None:
    """Emit a single-line structured JSON log without any prompt or completion content."""
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        **event,
    }
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


class RouterServerConfig:
    """Runtime server and upstream endpoint configuration."""

    def __init__(
        self,
        router_config: Optional[RouterConfig] = None,
        model_upstreams: Optional[Dict[str, str]] = None,
        upstream_timeout_sec: float = 90.0,
    ) -> None:
        self.router_config = router_config or RouterConfig.from_env()
        self.upstream_timeout_sec = float(
            os.environ.get("AUTO_ROUTER_UPSTREAM_TIMEOUT_SEC", str(upstream_timeout_sec))
        )
        default_upstreams = {
            COMPLEX_MODEL: os.environ.get(
                "AUTO_ROUTER_QWEN_UPSTREAM",
                "http://qwen-demo.default.svc.cluster.local:8080",
            ),
            SIMPLE_MODEL: os.environ.get(
                "AUTO_ROUTER_SMOLLM_UPSTREAM",
                "http://smollm-demo.default.svc.cluster.local:8080",
            ),
        }
        self.model_upstreams = model_upstreams or default_upstreams

    def resolve_upstream(self, model_name: str) -> Tuple[str, int, str]:
        raw_url = self.model_upstreams.get(model_name)
        if not raw_url:
            raise KeyError(f"No upstream configured for model '{model_name}'")
        parsed = urllib.parse.urlparse(raw_url)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        base_path = parsed.path.rstrip("/")
        return host, port, base_path


class AutoModelRouterHandler(http.server.BaseHTTPRequestHandler):
    """HTTP/1.1 handler supporting both JSON and incremental SSE responses."""

    protocol_version = "HTTP/1.1"
    server_config: RouterServerConfig = RouterServerConfig()

    def log_message(self, format: str, *args: object) -> None:
        # Suppress default BaseHTTPRequestHandler stderr access log in favor of structured JSON logs
        return

    def _get_request_id(self) -> str:
        for hdr in ("X-Request-Id", "X-Correlation-Id"):
            val = self.headers.get(hdr)
            if val and val.strip():
                return val.strip()[:128]
        return str(uuid.uuid4())

    def _send_json(
        self,
        status_code: int,
        payload: Dict[str, object],
        extra_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _read_bounded_body(self, max_bytes: int) -> bytes:
        """Read request body up to max_bytes + 1 so oversized payloads are caught safely."""
        transfer_encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in transfer_encoding:
            chunks = bytearray()
            while True:
                line = self.rfile.readline(65536)
                if not line:
                    break
                size_str = line.split(b";", 1)[0].strip()
                try:
                    chunk_len = int(size_str, 16)
                except ValueError as exc:
                    raise RequestValidationError(400, "invalid_chunked_body", "Malformed chunked encoding.") from exc
                if chunk_len == 0:
                    # Consume trailing CRLF
                    self.rfile.readline(65536)
                    break
                if len(chunks) + chunk_len > max_bytes:
                    raise RequestValidationError(
                        400,
                        "payload_too_large",
                        f"Request body exceeds maximum allowed ({max_bytes} bytes).",
                    )
                data = self.rfile.read(chunk_len)
                chunks.extend(data)
                # Consume trailing CRLF after chunk
                self.rfile.readline(65536)
            return bytes(chunks)

        content_length_hdr = self.headers.get("Content-Length")
        if content_length_hdr is None:
            raise RequestValidationError(400, "missing_content_length", "Content-Length header is required.")
        try:
            content_length = int(content_length_hdr)
        except ValueError as exc:
            raise RequestValidationError(400, "invalid_content_length", "Invalid Content-Length header.") from exc

        if content_length < 0:
            raise RequestValidationError(400, "invalid_content_length", "Negative Content-Length is invalid.")

        if content_length > max_bytes:
            # Read only a small drain window and close connection to avoid buffering huge bodies
            raise RequestValidationError(
                400,
                "payload_too_large",
                f"Request body size ({content_length} bytes) exceeds maximum allowed ({max_bytes} bytes).",
            )

        if content_length == 0:
            return b""

        return self.rfile.read(content_length)

    def do_GET(self) -> None:
        parsed_path = urllib.parse.urlparse(self.path).path
        if parsed_path in ("/health", "/healthz"):
            self._send_json(200, {"status": "ok", "service": "auto-model-router"})
            return
        self._send_json(
            404,
            {
                "error": {
                    "message": f"Unknown path '{parsed_path}'. Use POST /v1/chat/completions.",
                    "type": "not_found_error",
                    "code": "path_not_found",
                }
            },
        )

    def do_POST(self) -> None:
        start_time = time.monotonic()
        req_id = self._get_request_id()
        parsed_path = urllib.parse.urlparse(self.path).path

        if parsed_path != "/v1/chat/completions":
            self._send_json(
                404,
                {
                    "error": {
                        "message": f"Unknown endpoint '{parsed_path}'. Expected '/v1/chat/completions'.",
                        "type": "not_found_error",
                        "code": "endpoint_not_found",
                    }
                },
                extra_headers={"X-Request-Id": req_id},
            )
            return

        cfg = self.server_config.router_config

        try:
            raw_body = self._read_bounded_body(cfg.max_body_bytes)
            decision, forwarded_body = evaluate_chat_request(raw_body, cfg)
        except RequestValidationError as exc:
            dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
            log_json(
                {
                    "level": "warn",
                    "msg": "request rejected",
                    "request_id": req_id,
                    "status": exc.status_code,
                    "error_code": exc.code,
                    "duration_ms": dur_ms,
                }
            )
            self._send_json(
                exc.status_code,
                exc.to_openai_error(),
                extra_headers={"X-Request-Id": req_id},
            )
            return
        except Exception as exc:
            dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
            log_json(
                {
                    "level": "error",
                    "msg": "unexpected validation error",
                    "request_id": req_id,
                    "error": str(exc),
                    "duration_ms": dur_ms,
                }
            )
            self._send_json(
                400,
                {
                    "error": {
                        "message": "Malformed request.",
                        "type": "invalid_request_error",
                        "code": "malformed_request",
                    }
                },
                extra_headers={"X-Request-Id": req_id},
            )
            return

        route_headers = {
            "X-Auto-Selected-Model": decision.selected_model,
            "X-Auto-Route-Reason": decision.reason,
            "X-Auto-Route-Mode": decision.mode,
            "X-Request-Id": req_id,
        }

        try:
            up_host, up_port, up_base_path = self.server_config.resolve_upstream(decision.selected_model)
        except KeyError as exc:
            self._send_json(
                502,
                {
                    "error": {
                        "message": str(exc),
                        "type": "server_error",
                        "code": "upstream_not_configured",
                    }
                },
                extra_headers=route_headers,
            )
            return

        upstream_target = f"{up_base_path}/v1/chat/completions"
        conn: Optional[http.client.HTTPConnection] = None

        try:
            conn = http.client.HTTPConnection(
                up_host,
                up_port,
                timeout=self.server_config.upstream_timeout_sec,
            )
            up_req_headers = {
                "Content-Type": "application/json",
                "Content-Length": str(len(forwarded_body)),
                "Accept": self.headers.get("Accept", "*/*"),
                "X-Request-Id": req_id,
            }
            conn.request("POST", upstream_target, body=forwarded_body, headers=up_req_headers)
            up_resp = conn.getresponse()
            up_status = up_resp.status
            up_content_type = up_resp.getheader("Content-Type", "application/json")
            is_sse = decision.stream or up_content_type.lower().startswith("text/event-stream")

            if is_sse and up_status == 200:
                self.send_response(up_status)
                self.send_header("Content-Type", up_content_type)
                self.send_header("Cache-Control", "no-cache")
                self.send_header("X-Accel-Buffering", "no")
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Connection", "close")
                for k, v in route_headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.flush()

                chunks_forwarded = 0
                while True:
                    line = up_resp.readline()
                    if not line:
                        break
                    chunk_header = f"{len(line):X}\r\n".encode("ascii")
                    self.wfile.write(chunk_header)
                    self.wfile.write(line)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
                    chunks_forwarded += 1

                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()

                dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
                log_json(
                    {
                        "level": "info",
                        "msg": "routed chat completion request",
                        "request_id": req_id,
                        "mode": decision.mode,
                        "selected_model": decision.selected_model,
                        "reason": decision.reason,
                        "stream": True,
                        "user_input_chars": decision.user_input_chars,
                        "requested_max_tokens": decision.requested_max_tokens,
                        "upstream": f"{up_host}:{up_port}",
                        "status": up_status,
                        "sse_lines_forwarded": chunks_forwarded,
                        "duration_ms": dur_ms,
                    }
                )
            else:
                resp_body = up_resp.read()
                self.send_response(up_status)
                self.send_header("Content-Type", up_content_type)
                self.send_header("Content-Length", str(len(resp_body)))
                self.send_header("Connection", "close")
                for k, v in route_headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp_body)
                self.wfile.flush()

                dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
                log_json(
                    {
                        "level": "info",
                        "msg": "routed chat completion request",
                        "request_id": req_id,
                        "mode": decision.mode,
                        "selected_model": decision.selected_model,
                        "reason": decision.reason,
                        "stream": False,
                        "user_input_chars": decision.user_input_chars,
                        "requested_max_tokens": decision.requested_max_tokens,
                        "upstream": f"{up_host}:{up_port}",
                        "status": up_status,
                        "response_bytes": len(resp_body),
                        "duration_ms": dur_ms,
                    }
                )
        except (socket.timeout, TimeoutError) as exc:
            dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
            log_json(
                {
                    "level": "error",
                    "msg": "upstream request timed out",
                    "request_id": req_id,
                    "mode": decision.mode,
                    "selected_model": decision.selected_model,
                    "reason": decision.reason,
                    "upstream": f"{up_host}:{up_port}",
                    "error": str(exc),
                    "duration_ms": dur_ms,
                }
            )
            self._send_json(
                504,
                {
                    "error": {
                        "message": f"Upstream model server '{decision.selected_model}' timed out.",
                        "type": "upstream_error",
                        "code": "upstream_timeout",
                    }
                },
                extra_headers=route_headers,
            )
        except Exception as exc:
            dur_ms = round((time.monotonic() - start_time) * 1000.0, 2)
            log_json(
                {
                    "level": "error",
                    "msg": "upstream request failed",
                    "request_id": req_id,
                    "mode": decision.mode,
                    "selected_model": decision.selected_model,
                    "reason": decision.reason,
                    "upstream": f"{up_host}:{up_port}",
                    "error": str(exc),
                    "duration_ms": dur_ms,
                }
            )
            try:
                self._send_json(
                    502,
                    {
                        "error": {
                            "message": f"Failed to reach upstream model server '{decision.selected_model}': {exc}",
                            "type": "upstream_error",
                            "code": "upstream_unavailable",
                        }
                    },
                    extra_headers=route_headers,
                )
            except Exception:
                pass
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


def run_server(host: str = "0.0.0.0", port: int = 8080) -> None:
    server_cfg = RouterServerConfig()
    AutoModelRouterHandler.server_config = server_cfg
    httpd = http.server.ThreadingHTTPServer((host, port), AutoModelRouterHandler)
    log_json(
        {
            "level": "info",
            "msg": "auto-model-router listening",
            "host": host,
            "port": port,
            "long_input_chars": server_cfg.router_config.long_input_chars,
            "long_output_tokens": server_cfg.router_config.long_output_tokens,
            "max_body_bytes": server_cfg.router_config.max_body_bytes,
            "upstreams": server_cfg.model_upstreams,
        }
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    listen_port = int(os.environ.get("PORT", "8080"))
    run_server(host="0.0.0.0", port=listen_port)
