#!/usr/bin/env python3
"""Automated unit and HTTP contract test suite for the rule-based automatic model router.

Covers:
- Section 7.A: Table-driven classifier unit tests (>= 25 cases + exact threshold boundaries).
- Section 7.B: Request contract tests (all 13 required contract cases + live HTTP/SSE proxy verification).
"""

from __future__ import annotations

import http.client
import http.server
import io
import json
import threading
import unittest
from typing import Any, Dict, List, Optional, Tuple

from router.classifier import (
    COMPLEX_MODEL,
    REASON_ARCHITECTURE_REQUEST,
    REASON_CODE_REQUEST,
    REASON_DEFAULT_SIMPLE,
    REASON_EXPLICIT_MODEL,
    REASON_LARGE_OUTPUT,
    REASON_LONG_INPUT,
    REASON_MATH_REQUEST,
    REASON_REASONING_REQUEST,
    SIMPLE_MODEL,
    RequestValidationError,
    RouterConfig,
    classify_user_input,
    evaluate_chat_request,
)
from router.server import AutoModelRouterHandler, RouterServerConfig


class ClassifierTableUnitTest(unittest.TestCase):
    """Section 7.A: Table-driven unit tests for deterministic complexity classification."""

    def setUp(self) -> None:
        self.config = RouterConfig(long_input_chars=1200, long_output_tokens=256)

    def test_table_driven_classification_examples(self) -> None:
        # (description, user_text, max_tokens, expected_model, expected_reason)
        test_cases: List[Tuple[str, str, Optional[int], str, str]] = [
            # Simple requests -> smollm-demo
            (
                "greeting_hi",
                "Hi",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "what_is_kubernetes",
                "What is Kubernetes?",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "explain_containers_two_sentences",
                "Explain containers in two sentences",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "simple_short_answer",
                "Name the capital of France in one word.",
                16,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "short_summary_request",
                "Summarize the main benefit of cloud computing in one sentence.",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "ordinary_technical_question_with_python_keyword",
                "Why is Python popular among beginners?",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "ordinary_technical_question_with_terraform_keyword",
                "What does Terraform do in cloud infrastructure?",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "ordinary_technical_question_with_pod_keyword",
                "What is a Pod in Kubernetes and why does it exist?",
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            # Code / debugging / manifest requests -> qwen-demo
            (
                "write_go_program_json",
                "Write a Go program that parses JSON",
                100,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "debug_stack_trace",
                "Debug this stack trace",
                100,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "generate_terraform_gke",
                "Generate a Terraform configuration for GKE",
                100,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "create_kubernetes_deployment_manifest",
                "Create a Kubernetes manifest for an nginx Deployment with 2 replicas.",
                128,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "code_fence_snippet",
                "Explain what this snippet does:\n```python\ndef add(a, b):\n    return a + b\n```",
                64,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "refactor_function",
                "Refactor this function to avoid nested loops and improve readability.",
                100,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            # Architecture / trade-off / comparison requests -> qwen-demo
            (
                "compare_k8s_networking_tradeoffs",
                "Compare two Kubernetes networking architectures and explain the trade-offs",
                128,
                COMPLEX_MODEL,
                REASON_ARCHITECTURE_REQUEST,
            ),
            (
                "root_cause_analysis",
                "Perform a root-cause analysis for cascading timeouts in a microservices system.",
                128,
                COMPLEX_MODEL,
                REASON_ARCHITECTURE_REQUEST,
            ),
            (
                "system_design_distributed_cache",
                "Design a distributed cache architecture with high-availability and low latency.",
                128,
                COMPLEX_MODEL,
                REASON_ARCHITECTURE_REQUEST,
            ),
            # Multi-step reasoning requests -> qwen-demo
            (
                "multi_step_reasoning_step_by_step",
                "Explain step by step how TCP three-way handshake and congestion control interact.",
                128,
                COMPLEX_MODEL,
                REASON_REASONING_REQUEST,
            ),
            (
                "logic_puzzle_deduction",
                "Solve this logic puzzle and deduce which server holds the primary lock.",
                128,
                COMPLEX_MODEL,
                REASON_REASONING_REQUEST,
            ),
            # Mathematical calculation requests -> qwen-demo
            (
                "substantial_math_calculation",
                "Calculate (482 * 19) + (375 / 15) - 128 and verify the result.",
                64,
                COMPLEX_MODEL,
                REASON_MATH_REQUEST,
            ),
            (
                "compound_interest_calculation",
                "Compute the compound interest on 15000 at 6.5% annual rate over 8 years.",
                64,
                COMPLEX_MODEL,
                REASON_MATH_REQUEST,
            ),
            # Threshold boundary tests: user input length around 1200 chars
            (
                "input_length_below_threshold_1199",
                "a" * 1199,
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "input_length_at_threshold_1200",
                "a" * 1200,
                64,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "input_length_above_threshold_1201",
                "a" * 1201,
                64,
                COMPLEX_MODEL,
                REASON_LONG_INPUT,
            ),
            # Threshold boundary tests: max_tokens around 256
            (
                "max_tokens_below_threshold_255",
                "Tell me a story about a lighthouse.",
                255,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "max_tokens_at_threshold_256",
                "Tell me a story about a lighthouse.",
                256,
                SIMPLE_MODEL,
                REASON_DEFAULT_SIMPLE,
            ),
            (
                "max_tokens_above_threshold_257",
                "Tell me a story about a lighthouse.",
                257,
                COMPLEX_MODEL,
                REASON_LARGE_OUTPUT,
            ),
            # Precedence verification when multiple complexity rules match simultaneously
            (
                "precedence_code_over_large_output",
                "Write a Go program that parses JSON",
                512,
                COMPLEX_MODEL,
                REASON_CODE_REQUEST,
            ),
            (
                "precedence_reasoning_over_long_input",
                "Explain step by step " + ("the history of cloud computing " * 45),
                64,
                COMPLEX_MODEL,
                REASON_REASONING_REQUEST,
            ),
        ]

        for name, text, max_tok, exp_model, exp_reason in test_cases:
            with self.subTest(case=name):
                model, reason = classify_user_input(
                    user_text=text,
                    requested_max_tokens=max_tok,
                    config=self.config,
                )
                self.assertEqual(
                    model,
                    exp_model,
                    f"Case '{name}': expected model '{exp_model}', got '{model}' (reason='{reason}')",
                )
                self.assertEqual(
                    reason,
                    exp_reason,
                    f"Case '{name}': expected reason '{exp_reason}', got '{reason}'",
                )

    def test_system_message_ignored_in_input_length(self) -> None:
        """System messages must not trigger long-input when the user message is short."""
        payload = {
            "messages": [
                {"role": "system", "content": "S" * 2000},
                {"role": "user", "content": "Hi"},
            ],
            "max_tokens": 32,
        }
        decision, _ = evaluate_chat_request(json.dumps(payload).encode("utf-8"), self.config)
        self.assertEqual(decision.selected_model, SIMPLE_MODEL)
        self.assertEqual(decision.reason, REASON_DEFAULT_SIMPLE)
        self.assertEqual(decision.user_input_chars, 2)

    def test_multi_turn_user_messages_aggregated(self) -> None:
        """All user messages in a conversation must be analyzed, not just the final word."""
        payload = {
            "messages": [
                {"role": "user", "content": "Write a Go program that parses JSON"},
                {"role": "assistant", "content": "Sure, here is an example..."},
                {"role": "user", "content": "Thanks, please make it concise."},
            ],
            "max_tokens": 64,
        }
        decision, _ = evaluate_chat_request(json.dumps(payload).encode("utf-8"), self.config)
        self.assertEqual(decision.selected_model, COMPLEX_MODEL)
        self.assertEqual(decision.reason, REASON_CODE_REQUEST)


class RequestContractTest(unittest.TestCase):
    """Section 7.B: Request contract tests for all 13 required scenarios."""

    def setUp(self) -> None:
        self.config = RouterConfig(
            long_input_chars=1200,
            long_output_tokens=256,
            max_body_bytes=4096,
        )

    def test_1_recognized_explicit_qwen_demo(self) -> None:
        body = json.dumps(
            {
                "model": "qwen-demo",
                "messages": [{"role": "user", "content": "Hi"}],
                "max_tokens": 16,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, "qwen-demo")
        self.assertEqual(decision.mode, "explicit")
        self.assertEqual(decision.reason, REASON_EXPLICIT_MODEL)
        self.assertEqual(json.loads(forwarded)["model"], "qwen-demo")

    def test_2_recognized_explicit_smollm_demo(self) -> None:
        # Even if the prompt is a complex code prompt, explicit smollm-demo MUST be preserved!
        body = json.dumps(
            {
                "model": "smollm-demo",
                "messages": [{"role": "user", "content": "Write a Go program that parses JSON"}],
                "max_tokens": 64,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, "smollm-demo")
        self.assertEqual(decision.mode, "explicit")
        self.assertEqual(decision.reason, REASON_EXPLICIT_MODEL)
        self.assertEqual(json.loads(forwarded)["model"], "smollm-demo")

    def test_3_missing_model_field(self) -> None:
        body = json.dumps(
            {
                "messages": [{"role": "user", "content": "Explain Kubernetes in two short sentences."}],
                "max_tokens": 64,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, SIMPLE_MODEL)
        self.assertEqual(decision.mode, "auto")
        self.assertEqual(decision.reason, REASON_DEFAULT_SIMPLE)
        self.assertEqual(json.loads(forwarded)["model"], SIMPLE_MODEL)

    def test_4_empty_model_field(self) -> None:
        body = json.dumps(
            {
                "model": "",
                "messages": [{"role": "user", "content": "Write a Go program that parses JSON"}],
                "max_tokens": 64,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, COMPLEX_MODEL)
        self.assertEqual(decision.mode, "auto")
        self.assertEqual(decision.reason, REASON_CODE_REQUEST)
        self.assertEqual(json.loads(forwarded)["model"], COMPLEX_MODEL)

    def test_5_null_model_field(self) -> None:
        body = json.dumps(
            {
                "model": None,
                "messages": [{"role": "user", "content": "What is Kubernetes?"}],
                "max_tokens": 64,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, SIMPLE_MODEL)
        self.assertEqual(decision.mode, "auto")
        self.assertEqual(json.loads(forwarded)["model"], SIMPLE_MODEL)

    def test_6_whitespace_only_model_field(self) -> None:
        body = json.dumps(
            {
                "model": "   \t\n  ",
                "messages": [{"role": "user", "content": "Debug this stack trace"}],
                "max_tokens": 64,
            }
        ).encode("utf-8")
        decision, forwarded = evaluate_chat_request(body, self.config)
        self.assertEqual(decision.selected_model, COMPLEX_MODEL)
        self.assertEqual(decision.mode, "auto")
        self.assertEqual(decision.reason, REASON_CODE_REQUEST)
        self.assertEqual(json.loads(forwarded)["model"], COMPLEX_MODEL)

    def test_7_unknown_explicit_model_returns_404(self) -> None:
        for bad_model in ("nonexistent-model", "gpt-4", "qwen", "smollm", " qwen-demo "):
            with self.subTest(model=bad_model):
                body = json.dumps(
                    {
                        "model": bad_model,
                        "messages": [{"role": "user", "content": "Hi"}],
                    }
                ).encode("utf-8")
                with self.assertRaises(RequestValidationError) as ctx:
                    evaluate_chat_request(body, self.config)
                self.assertEqual(ctx.exception.status_code, 404)
                self.assertEqual(ctx.exception.code, "model_not_found")

    def test_8_wrong_model_field_type_returns_400(self) -> None:
        for invalid_type_val in (123, True, False, ["qwen-demo"], {"name": "qwen-demo"}):
            with self.subTest(val=invalid_type_val):
                body = json.dumps(
                    {
                        "model": invalid_type_val,
                        "messages": [{"role": "user", "content": "Hi"}],
                    }
                ).encode("utf-8")
                with self.assertRaises(RequestValidationError) as ctx:
                    evaluate_chat_request(body, self.config)
                self.assertEqual(ctx.exception.status_code, 400)
                self.assertEqual(ctx.exception.code, "invalid_model_type")

    def test_9_invalid_json_returns_400(self) -> None:
        for raw in (b"{not valid json", b"", b"[]", b'"just a string"'):
            with self.subTest(raw=raw):
                with self.assertRaises(RequestValidationError) as ctx:
                    evaluate_chat_request(raw, self.config)
                self.assertEqual(ctx.exception.status_code, 400)

    def test_10_missing_messages_returns_400(self) -> None:
        body = json.dumps({"max_tokens": 32}).encode("utf-8")
        with self.assertRaises(RequestValidationError) as ctx:
            evaluate_chat_request(body, self.config)
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(ctx.exception.code, "missing_messages")

    def test_11_malformed_messages_structure_returns_400(self) -> None:
        malformed_cases: List[Any] = [
            [],
            "not-a-list",
            ["not-an-object"],
            [{"role": "invalid_role", "content": "Hi"}],
            [{"role": "user"}],  # missing content
            [{"role": "user", "content": None}],  # null content on user role
            [{"role": "user", "content": "   "}],  # blank-only user content
            [{"role": "system", "content": "Only system message, no user message"}],
            [{"role": "user", "content": 12345}],
        ]
        for idx, msgs in enumerate(malformed_cases):
            with self.subTest(case_index=idx):
                body = json.dumps({"messages": msgs}).encode("utf-8")
                with self.assertRaises(RequestValidationError) as ctx:
                    evaluate_chat_request(body, self.config)
                self.assertEqual(ctx.exception.status_code, 400)
                self.assertEqual(ctx.exception.code, "malformed_messages")

    def test_12_oversized_request_body_returns_400(self) -> None:
        huge_body = json.dumps(
            {
                "messages": [{"role": "user", "content": "x" * 5000}],
            }
        ).encode("utf-8")
        with self.assertRaises(RequestValidationError) as ctx:
            evaluate_chat_request(huge_body, self.config)
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(ctx.exception.code, "payload_too_large")

    def test_13_missing_or_invalid_max_tokens(self) -> None:
        # Missing max_tokens is valid
        valid_body = json.dumps(
            {"messages": [{"role": "user", "content": "What is Kubernetes?"}]}
        ).encode("utf-8")
        decision, _ = evaluate_chat_request(valid_body, self.config)
        self.assertIsNone(decision.requested_max_tokens)
        self.assertEqual(decision.selected_model, SIMPLE_MODEL)

        # Invalid max_tokens values must return 400
        for bad_tok in (0, -10, "64", True, False, 3.14, 999999):
            with self.subTest(max_tokens=bad_tok):
                body = json.dumps(
                    {
                        "messages": [{"role": "user", "content": "Hi"}],
                        "max_tokens": bad_tok,
                    }
                ).encode("utf-8")
                with self.assertRaises(RequestValidationError) as ctx:
                    evaluate_chat_request(body, self.config)
                self.assertEqual(ctx.exception.status_code, 400)
                self.assertEqual(ctx.exception.code, "invalid_max_tokens")


class _MockModelBackendHandler(http.server.BaseHTTPRequestHandler):
    """Local mock model server that echoes the received model name for HTTP proxy contract tests."""

    protocol_version = "HTTP/1.1"
    backend_id: str = "mock"

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        model_in_body = body.get("model", "")
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Connection", "close")
            self.end_headers()
            events = [
                {"model": model_in_body, "choices": [{"index": 0, "delta": {"role": "assistant", "content": None}}]},
                {"model": model_in_body, "choices": [{"index": 0, "delta": {"content": f"Hello from {self.backend_id}"}}]},
                {"model": model_in_body, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ]
            for ev in events:
                self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode("utf-8"))
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        else:
            resp = json.dumps(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion",
                    "model": model_in_body,
                    "backend": self.backend_id,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": f"Served by {self.backend_id}"},
                            "finish_reason": "stop",
                        }
                    ],
                }
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(resp)
            self.wfile.flush()


class RouterHTTPIntegrationTest(unittest.TestCase):
    """End-to-end HTTP server contract tests verifying headers, status codes, and SSE streaming."""

    @classmethod
    def setUpClass(cls) -> None:
        class QwenMockHandler(_MockModelBackendHandler):
            backend_id = "qwen-mock-backend"

        class SmollmMockHandler(_MockModelBackendHandler):
            backend_id = "smollm-mock-backend"

        cls.qwen_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QwenMockHandler)
        cls.smollm_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SmollmMockHandler)
        qwen_port = cls.qwen_srv.server_address[1]
        smollm_port = cls.smollm_srv.server_address[1]

        router_cfg = RouterConfig(long_input_chars=1200, long_output_tokens=256, max_body_bytes=4096)
        srv_cfg = RouterServerConfig(
            router_config=router_cfg,
            model_upstreams={
                COMPLEX_MODEL: f"http://127.0.0.1:{qwen_port}",
                SIMPLE_MODEL: f"http://127.0.0.1:{smollm_port}",
            },
        )

        class BoundRouterHandler(AutoModelRouterHandler):
            server_config = srv_cfg

        cls.router_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), BoundRouterHandler)
        cls.router_port = cls.router_srv.server_address[1]

        for s in (cls.qwen_srv, cls.smollm_srv, cls.router_srv):
            t = threading.Thread(target=s.serve_forever, daemon=True)
            t.start()

    @classmethod
    def tearDownClass(cls) -> None:
        for s in (cls.router_srv, cls.qwen_srv, cls.smollm_srv):
            s.shutdown()
            s.server_close()

    def _post(self, body_bytes: bytes) -> Tuple[int, Dict[str, str], bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.router_port, timeout=10)
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=body_bytes,
            headers={"Content-Type": "application/json", "Content-Length": str(len(body_bytes))},
        )
        resp = conn.getresponse()
        headers = {k.lower(): v for k, v in resp.getheaders()}
        data = resp.read()
        status = resp.status
        conn.close()
        return status, headers, data

    def test_http_auto_simple_routes_to_smollm(self) -> None:
        status, headers, data = self._post(
            json.dumps({"messages": [{"role": "user", "content": "What is Kubernetes?"}]}).encode("utf-8")
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-auto-selected-model"), "smollm-demo")
        self.assertEqual(headers.get("x-auto-route-reason"), "default-simple")
        self.assertEqual(headers.get("x-auto-route-mode"), "auto")
        body = json.loads(data.decode("utf-8"))
        self.assertEqual(body["model"], "smollm-demo")
        self.assertEqual(body["backend"], "smollm-mock-backend")

    def test_http_auto_complex_routes_to_qwen(self) -> None:
        status, headers, data = self._post(
            json.dumps({"messages": [{"role": "user", "content": "Write a Go program that parses JSON"}]}).encode("utf-8")
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-auto-selected-model"), "qwen-demo")
        self.assertEqual(headers.get("x-auto-route-reason"), "code-request")
        self.assertEqual(headers.get("x-auto-route-mode"), "auto")
        body = json.loads(data.decode("utf-8"))
        self.assertEqual(body["model"], "qwen-demo")
        self.assertEqual(body["backend"], "qwen-mock-backend")

    def test_http_unknown_model_returns_404(self) -> None:
        status, _, data = self._post(
            json.dumps({"model": "unknown-xyz", "messages": [{"role": "user", "content": "Hi"}]}).encode("utf-8")
        )
        self.assertEqual(status, 404)
        body = json.loads(data.decode("utf-8"))
        self.assertEqual(body["error"]["code"], "model_not_found")

    def test_http_sse_streaming_passthrough(self) -> None:
        status, headers, data = self._post(
            json.dumps(
                {
                    "messages": [{"role": "user", "content": "Write a Python script to sort a list"}],
                    "stream": True,
                }
            ).encode("utf-8")
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-auto-selected-model"), "qwen-demo")
        self.assertEqual(headers.get("x-auto-route-reason"), "code-request")
        text = data.decode("utf-8")
        self.assertIn("Hello from qwen-mock-backend", text)
        self.assertIn("data: [DONE]", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
