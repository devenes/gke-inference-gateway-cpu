#!/usr/bin/env python3
"""Deterministic, explainable rule-based model classifier and request validator.

Supports two request modes behind a single OpenAI-compatible /v1/chat/completions endpoint:
- Mode A (Explicit model selection): Preserves recognized explicit model names
  ('qwen-demo', 'smollm-demo') and rejects non-empty unknown models with HTTP 404.
- Mode B (Automatic model selection): When 'model' is absent, null, empty, or
  whitespace-only, classifies the user messages using a deterministic rule engine:
    1. code-request         -> qwen-demo
    2. reasoning-request    -> qwen-demo
    3. architecture-request -> qwen-demo
    4. math-request         -> qwen-demo
    5. long-input           -> qwen-demo (user chars > AUTO_ROUTER_LONG_INPUT_CHARS)
    6. large-output         -> qwen-demo (max_tokens > AUTO_ROUTER_LONG_OUTPUT_TOKENS)
    7. default-simple       -> smollm-demo
"""

from __future__ import annotations

import dataclasses
import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple

COMPLEX_MODEL = "qwen-demo"
SIMPLE_MODEL = "smollm-demo"
DEFAULT_RECOGNIZED_MODELS: Tuple[str, ...] = (COMPLEX_MODEL, SIMPLE_MODEL)

REASON_EXPLICIT_MODEL = "explicit-model"
REASON_CODE_REQUEST = "code-request"
REASON_REASONING_REQUEST = "reasoning-request"
REASON_ARCHITECTURE_REQUEST = "architecture-request"
REASON_MATH_REQUEST = "math-request"
REASON_LONG_INPUT = "long-input"
REASON_LARGE_OUTPUT = "large-output"
REASON_DEFAULT_SIMPLE = "default-simple"

VALID_ROLES = frozenset({"system", "user", "assistant", "developer", "tool"})


@dataclasses.dataclass(frozen=True)
class RouterConfig:
    """Configuration and safety bounds for the rule-based automatic router."""

    long_input_chars: int = 1200
    long_output_tokens: int = 256
    max_body_bytes: int = 65536
    max_messages: int = 64
    max_tokens_limit: int = 4096
    complex_model: str = COMPLEX_MODEL
    simple_model: str = SIMPLE_MODEL
    recognized_models: Tuple[str, ...] = DEFAULT_RECOGNIZED_MODELS

    @classmethod
    def from_env(cls) -> "RouterConfig":
        return cls(
            long_input_chars=int(os.environ.get("AUTO_ROUTER_LONG_INPUT_CHARS", "1200")),
            long_output_tokens=int(os.environ.get("AUTO_ROUTER_LONG_OUTPUT_TOKENS", "256")),
            max_body_bytes=int(os.environ.get("AUTO_ROUTER_MAX_BODY_BYTES", "65536")),
            max_messages=int(os.environ.get("AUTO_ROUTER_MAX_MESSAGES", "64")),
            max_tokens_limit=int(os.environ.get("AUTO_ROUTER_MAX_TOKENS_LIMIT", "4096")),
            complex_model=os.environ.get("AUTO_ROUTER_COMPLEX_MODEL", COMPLEX_MODEL),
            simple_model=os.environ.get("AUTO_ROUTER_SIMPLE_MODEL", SIMPLE_MODEL),
        )


@dataclasses.dataclass(frozen=True)
class RoutingDecision:
    """Explainable routing decision produced for a validated request."""

    selected_model: str
    mode: str  # "explicit" or "auto"
    reason: str
    user_input_chars: int
    requested_max_tokens: Optional[int]
    stream: bool


class RequestValidationError(Exception):
    """Structured HTTP validation error for malformed or unrecognized requests."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message

    def to_openai_error(self) -> Dict[str, Any]:
        err_type = "not_found_error" if self.status_code == 404 else "invalid_request_error"
        return {
            "error": {
                "message": self.message,
                "type": err_type,
                "code": self.code,
            }
        }


# ---------------------------------------------------------------------------
# Compiled deterministic complexity patterns
# ---------------------------------------------------------------------------

CODE_PATTERNS: Tuple[re.Pattern[str], ...] = (
    # Markdown code fences or substantial inline code constructs
    re.compile(r"```"),
    re.compile(r"(?:^|\n)\s*(?:func\s+\w+\s*\(|package\s+main\b|def\s+[a-zA-Z_]\w*\s*\(|class\s+[a-zA-Z_]\w*[\s:(]|#include\s*<|SELECT\s+.+\s+FROM\s+.+\s+WHERE\s+)", re.IGNORECASE),
    re.compile(r"(?:^|\n)\s*(?:apiVersion:\s*\S+|resource\s+\"[a-z0-9_]+\"\s+\"[a-z0-9_]+\")"),
    # Code generation / implementation requests
    re.compile(
        r"\b(?:write|implement|create|generate|build|code|draft|develop)\b.{0,50}\b"
        r"(?:program|script|function|class|method|module|cli|endpoint|microservice|sql\s+query|regex|regular\s+expression|unit\s+test|test\s+suite|dockerfile|makefile)\b",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\b(?:write|implement|create|generate|code)\b.{0,35}\b(?:in|using)\s+"
        r"(?:go|golang|python|javascript|typescript|rust|java|c\+\+|c#|bash|shell|zsh|sql|ruby|php)\b",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\b(?:write|implement|generate)\s+(?:a|an)\s+"
        r"(?:go|golang|python|javascript|typescript|rust|java|c\+\+|c#|bash|shell|sql)\b",
        re.IGNORECASE,
    ),
    # Debugging, stack traces, refactoring, and code review
    re.compile(
        r"\b(?:debug|fix|troubleshoot|diagnose)\b.{0,45}\b"
        r"(?:code|function|script|bug|error|exception|stack\s*trace|traceback|segfault|segmentation\s+fault|panic|crash|compile|compiler)\b",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\b(?:stack\s*trace|traceback|nullpointerexception|segmentation\s+fault|syntaxerror|typeerror|keyerror|indexerror|panic:\s+runtime\s+error)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:refactor|code\s+review|review\s+this\s+(?:code|pr|pull\s+request|function)|optimize\s+this\s+(?:code|function|query|loop))\b",
        re.IGNORECASE,
    ),
    # Infrastructure-as-code & Kubernetes manifest generation
    re.compile(
        r"\b(?:generate|write|create|build|draft|provide)\b.{0,55}\b"
        r"(?:terraform|hcl|kubernetes\s+manifest|k8s\s+manifest|deployment\s+yaml|helm\s+chart|docker-compose|github\s+actions|ci/cd\s+pipeline|yaml\s+manifest|manifest\s+for)\b",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\b(?:terraform\s+(?:configuration|module|resource|provider\s+block|state\s+migration)|"
        r"kubernetes\s+(?:deployment|service|ingress|httproute|gateway|statefulset|daemonset)\s+(?:yaml|manifest|spec))\b",
        re.IGNORECASE,
    ),
)

REASONING_PATTERNS: Tuple[re.Pattern[str], ...] = (
    re.compile(
        r"\b(?:step\s+by\s+step|step-by-step|chain\s+of\s+thought|chain-of-thought|"
        r"walk\s+me\s+through\s+each\s+step|think\s+through\s+carefully|from\s+first\s+principles|"
        r"multi-step\s+reasoning|show\s+every\s+step|explain\s+each\s+step\s+in\s+detail)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:formal\s+proof|mathematical\s+induction|prove\s+that|logical\s+deduction|"
        r"deduce\s+which|solve\s+this\s+(?:logic\s+)?puzzle|syllogism)\b",
        re.IGNORECASE,
    ),
)

ARCHITECTURE_PATTERNS: Tuple[re.Pattern[str], ...] = (
    re.compile(
        r"\b(?:trade-off|trade-offs|tradeoff|tradeoffs|pros\s+and\s+cons)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:compare|comparison|contrast)\b.{0,65}\b"
        r"(?:architecture|architectures|design|designs|topology|topologies|approach|approaches|"
        r"pattern|patterns|protocol|protocols|strategy|strategies|networking)\b",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\b(?:architecture\s+design|system\s+design|design\s+a\s+(?:distributed|scalable|high-availability|fault-tolerant|multi-region|microservices)|"
        r"root-cause\s+analysis|root\s+cause\s+analysis|postmortem|failure\s+mode\s+analysis|"
        r"cap\s+theorem|consensus\s+algorithm|algorithm\s+design|time\s+and\s+space\s+complexity|big-o\s+complexity)\b",
        re.IGNORECASE,
    ),
)

MATH_PATTERNS: Tuple[re.Pattern[str], ...] = (
    # Multi-operator arithmetic or parenthesized mathematical expressions
    re.compile(r"\b\d+(?:\.\d+)?\s*[\*\/+\-\^]\s*\d+(?:\.\d+)?\s*[\*\/+\-\^=]\s*\d+"),
    re.compile(r"\(\s*\d+(?:\.\d+)?\s*[\*\/+\-\^]\s*\d+(?:\.\d+)?\s*\)\s*[\*\/+\-\^]"),
    re.compile(r"\b\d{2,}\s*[\*\/]\s*\d{2,}\b"),
    # Explicit mathematical problem-solving keywords
    re.compile(
        r"\b(?:calculate|compute|solve\s+for|evaluate\s+the\s+(?:integral|derivative|expression|limit|sum)|"
        r"integrate\s+|derivative\s+of|differential\s+equation|eigenvalue|eigenvector|"
        r"matrix\s+multiplication|standard\s+deviation|probability\s+of|binomial\s+distribution|"
        r"bayes(?:'|\s)?\s*theorem|compound\s+interest|quadratic\s+equation|system\s+of\s+equations|linear\s+algebra)\b",
        re.IGNORECASE,
    ),
)


def _extract_message_text(msg: Any, index: int) -> Tuple[str, str]:
    """Validate a single OpenAI chat message and return (role, extracted_text)."""
    if not isinstance(msg, dict):
        raise RequestValidationError(
            400,
            "malformed_messages",
            f"messages[{index}] must be a JSON object.",
        )

    role = msg.get("role")
    if not isinstance(role, str) or role not in VALID_ROLES:
        raise RequestValidationError(
            400,
            "malformed_messages",
            f"messages[{index}].role must be one of {sorted(VALID_ROLES)}.",
        )

    if "content" not in msg:
        raise RequestValidationError(
            400,
            "malformed_messages",
            f"messages[{index}].content is required.",
        )

    content = msg.get("content")
    if content is None:
        if role in {"assistant", "tool"}:
            return role, ""
        raise RequestValidationError(
            400,
            "malformed_messages",
            f"messages[{index}].content cannot be null for role '{role}'.",
        )

    if isinstance(content, str):
        return role, content

    if isinstance(content, list):
        if not content:
            raise RequestValidationError(
                400,
                "malformed_messages",
                f"messages[{index}].content array must not be empty.",
            )
        text_parts: List[str] = []
        for p_idx, part in enumerate(content):
            if not isinstance(part, dict):
                raise RequestValidationError(
                    400,
                    "malformed_messages",
                    f"messages[{index}].content[{p_idx}] must be an object.",
                )
            p_type = part.get("type", "text")
            if p_type == "text":
                p_text = part.get("text")
                if not isinstance(p_text, str):
                    raise RequestValidationError(
                        400,
                        "malformed_messages",
                        f"messages[{index}].content[{p_idx}].text must be a string.",
                    )
                text_parts.append(p_text)
        return role, "\n".join(text_parts)

    raise RequestValidationError(
        400,
        "malformed_messages",
        f"messages[{index}].content must be a string or array of content parts.",
    )


def classify_user_input(
    user_text: str,
    requested_max_tokens: Optional[int] = None,
    config: Optional[RouterConfig] = None,
) -> Tuple[str, str]:
    """Deterministically classify user input into (selected_model, reason_code).

    Evaluation precedence:
      1. code-request         -> qwen-demo
      2. reasoning-request    -> qwen-demo
      3. architecture-request -> qwen-demo
      4. math-request         -> qwen-demo
      5. long-input           -> qwen-demo (len(user_text) > config.long_input_chars)
      6. large-output         -> qwen-demo (requested_max_tokens > config.long_output_tokens)
      7. default-simple       -> smollm-demo
    """
    cfg = config or RouterConfig()

    for pattern in CODE_PATTERNS:
        if pattern.search(user_text):
            return cfg.complex_model, REASON_CODE_REQUEST

    for pattern in REASONING_PATTERNS:
        if pattern.search(user_text):
            return cfg.complex_model, REASON_REASONING_REQUEST

    for pattern in ARCHITECTURE_PATTERNS:
        if pattern.search(user_text):
            return cfg.complex_model, REASON_ARCHITECTURE_REQUEST

    for pattern in MATH_PATTERNS:
        if pattern.search(user_text):
            return cfg.complex_model, REASON_MATH_REQUEST

    if len(user_text) > cfg.long_input_chars:
        return cfg.complex_model, REASON_LONG_INPUT

    if requested_max_tokens is not None and requested_max_tokens > cfg.long_output_tokens:
        return cfg.complex_model, REASON_LARGE_OUTPUT

    return cfg.simple_model, REASON_DEFAULT_SIMPLE


def evaluate_chat_request(
    raw_body: bytes,
    config: Optional[RouterConfig] = None,
) -> Tuple[RoutingDecision, bytes]:
    """Parse, validate, and classify an OpenAI /v1/chat/completions request body.

    Returns (RoutingDecision, forwarded_json_bytes) where forwarded_json_bytes
    is guaranteed to contain the resolved 'model' identifier.
    Raises RequestValidationError (HTTP 400 or 404) on invalid input or unknown model.
    """
    cfg = config or RouterConfig()

    if not raw_body:
        raise RequestValidationError(400, "empty_body", "Request body must not be empty.")

    if len(raw_body) > cfg.max_body_bytes:
        raise RequestValidationError(
            400,
            "payload_too_large",
            f"Request body size ({len(raw_body)} bytes) exceeds maximum allowed ({cfg.max_body_bytes} bytes).",
        )

    try:
        decoded = raw_body.decode("utf-8")
        payload = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RequestValidationError(400, "invalid_json", f"Invalid JSON request body: {exc}") from exc

    if not isinstance(payload, dict):
        raise RequestValidationError(400, "invalid_json_object", "Top-level JSON body must be an object.")

    # Validate messages array
    if "messages" not in payload:
        raise RequestValidationError(400, "missing_messages", "Field 'messages' is required.")

    messages = payload.get("messages")
    if not isinstance(messages, list) or len(messages) == 0:
        raise RequestValidationError(400, "malformed_messages", "Field 'messages' must be a non-empty array.")

    if len(messages) > cfg.max_messages:
        raise RequestValidationError(
            400,
            "too_many_messages",
            f"Field 'messages' contains {len(messages)} items, exceeding limit of {cfg.max_messages}.",
        )

    user_texts: List[str] = []
    for idx, msg in enumerate(messages):
        role, text = _extract_message_text(msg, idx)
        if role == "user":
            user_texts.append(text)

    if not user_texts or not any(t.strip() for t in user_texts):
        raise RequestValidationError(
            400,
            "malformed_messages",
            "Field 'messages' must include at least one non-empty 'user' message.",
        )

    # Aggregate user messages (system/assistant messages are intentionally excluded from user input length)
    combined_user_text = "\n".join(user_texts)
    user_input_chars = len(combined_user_text)

    # Validate optional max_tokens / max_completion_tokens
    requested_max_tokens: Optional[int] = None
    for tok_field in ("max_tokens", "max_completion_tokens"):
        if tok_field in payload and payload[tok_field] is not None:
            val = payload[tok_field]
            if isinstance(val, bool) or not isinstance(val, int):
                raise RequestValidationError(
                    400,
                    "invalid_max_tokens",
                    f"Field '{tok_field}' must be a positive integer.",
                )
            if val <= 0 or val > cfg.max_tokens_limit:
                raise RequestValidationError(
                    400,
                    "invalid_max_tokens",
                    f"Field '{tok_field}' must be between 1 and {cfg.max_tokens_limit}.",
                )
            if requested_max_tokens is None:
                requested_max_tokens = val

    # Validate optional stream flag
    stream_val = payload.get("stream", False)
    if stream_val is not None and not isinstance(stream_val, bool):
        raise RequestValidationError(400, "invalid_stream_flag", "Field 'stream' must be a boolean.")
    stream = bool(stream_val)

    # Evaluate model field with strict precedence
    has_model_key = "model" in payload
    model_val = payload.get("model")

    if has_model_key and model_val is not None:
        if isinstance(model_val, bool) or not isinstance(model_val, str):
            raise RequestValidationError(
                400,
                "invalid_model_type",
                "Field 'model' must be a string or null when provided.",
            )
        if model_val.strip() != "":
            # Non-empty explicit model: must match a recognized model identifier exactly
            if model_val in cfg.recognized_models:
                decision = RoutingDecision(
                    selected_model=model_val,
                    mode="explicit",
                    reason=REASON_EXPLICIT_MODEL,
                    user_input_chars=user_input_chars,
                    requested_max_tokens=requested_max_tokens,
                    stream=stream,
                )
                payload["model"] = decision.selected_model
                return decision, json.dumps(payload).encode("utf-8")

            raise RequestValidationError(
                404,
                "model_not_found",
                f"Model '{model_val}' does not exist. Recognized models: {', '.join(cfg.recognized_models)}.",
            )

    # Model is absent, null, empty, or whitespace-only -> run deterministic rule classifier
    selected_model, reason = classify_user_input(
        user_text=combined_user_text,
        requested_max_tokens=requested_max_tokens,
        config=cfg,
    )
    decision = RoutingDecision(
        selected_model=selected_model,
        mode="auto",
        reason=reason,
        user_input_chars=user_input_chars,
        requested_max_tokens=requested_max_tokens,
        stream=stream,
    )
    payload["model"] = decision.selected_model
    forwarded_bytes = json.dumps(payload).encode("utf-8")
    return decision, forwarded_bytes
