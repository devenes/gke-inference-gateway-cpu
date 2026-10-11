#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"
NAMESPACE="${NAMESPACE:-default}"
STREAM_MAX_TOKENS="${STREAM_MAX_TOKENS:-64}"
STREAM_TIMEOUT_SEC="${STREAM_TIMEOUT_SEC:-45}"
STREAM_PROMPT="${STREAM_PROMPT:-Explain Kubernetes in two short sentences.}"

# Validate safety bounds
if ! [[ "${STREAM_MAX_TOKENS}" =~ ^[0-9]+$ ]] || (( STREAM_MAX_TOKENS < 1 || STREAM_MAX_TOKENS > 256 )); then
  echo "ERROR: STREAM_MAX_TOKENS must be an integer between 1 and 256 (got '${STREAM_MAX_TOKENS}')." >&2
  exit 1
fi
if ! [[ "${STREAM_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || (( STREAM_TIMEOUT_SEC < 5 || STREAM_TIMEOUT_SEC > 180 )); then
  echo "ERROR: STREAM_TIMEOUT_SEC must be an integer between 5 and 180 (got '${STREAM_TIMEOUT_SEC}')." >&2
  exit 1
fi

GW_IP="${GATEWAY_IP:-$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)}"
if [[ -z "${GW_IP}" ]]; then
  echo "ERROR: Could not discover external IP for Gateway '${GATEWAY_NAME}' in namespace '${NAMESPACE}'." >&2
  exit 1
fi

ENDPOINT="${GATEWAY_ENDPOINT:-http://${GW_IP}/v1/chat/completions}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${REPO_ROOT}/.results/streaming/${TIMESTAMP}"
mkdir -p "${OUT_DIR}"
ln -sfn "${TIMESTAMP}" "${REPO_ROOT}/.results/streaming/latest"

echo "============================================================"
echo " Streaming SSE Verification — GKE Inference Gateway CPU MVP"
echo "============================================================"
echo "Endpoint      : ${ENDPOINT}"
echo "Max Tokens    : ${STREAM_MAX_TOKENS}"
echo "Timeout (sec) : ${STREAM_TIMEOUT_SEC}"
echo "Artifacts Dir : ${OUT_DIR}"
echo ""

python3 - "${ENDPOINT}" "${OUT_DIR}" "${STREAM_MAX_TOKENS}" "${STREAM_TIMEOUT_SEC}" "${STREAM_PROMPT}" <<'PYEOF'
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

endpoint = sys.argv[1]
out_dir = sys.argv[2]
max_tokens = int(sys.argv[3])
timeout_sec = int(sys.argv[4])
prompt = sys.argv[5]

test_cases = [
    {
        "case_id": "explicit-qwen",
        "label": "Explicit qwen-demo",
        "model_field": "qwen-demo",
        "prompt": prompt,
        "expected_model": "qwen-demo",
        "expected_auto_reason": None,
    },
    {
        "case_id": "explicit-smollm",
        "label": "Explicit smollm-demo",
        "model_field": "smollm-demo",
        "prompt": prompt,
        "expected_model": "smollm-demo",
        "expected_auto_reason": None,
    },
    {
        "case_id": "auto-simple",
        "label": "Auto Simple (omitted model -> smollm-demo)",
        "model_field": None,
        "prompt": prompt,
        "expected_model": "smollm-demo",
        "expected_auto_reason": "default-simple",
    },
    {
        "case_id": "auto-complex",
        "label": "Auto Complex (omitted model -> qwen-demo)",
        "model_field": None,
        "prompt": "Write a Go program that parses JSON and prints a struct field.",
        "expected_model": "qwen-demo",
        "expected_auto_reason": "code-request",
    },
]

results = []
overall_failed = False

for tc in test_cases:
    case_id = tc["case_id"]
    expected_model = tc["expected_model"]
    print("------------------------------------------------------------")
    print(f" Streaming Test [{case_id}]: {tc['label']}")
    print("------------------------------------------------------------")

    payload = {
        "messages": [
            {"role": "user", "content": tc["prompt"]}
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
    }
    if tc["model_field"] is not None:
        payload["model"] = tc["model_field"]

    body_bytes = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=body_bytes,
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        method="POST",
    )

    sse_log_path = os.path.join(out_dir, f"{case_id}.sse.log")
    json_out_path = os.path.join(out_dir, f"{case_id}.json")

    t_start = time.perf_counter()
    http_status = 0
    content_type = ""
    auto_selected_hdr = ""
    auto_reason_hdr = ""
    t_headers = None
    t_first_sse_event = None
    t_first_content_token = None
    t_last_content_token = None
    content_chunk_timestamps = []
    sse_event_count = 0
    content_chunk_count = 0
    done_received = False
    returned_model = None
    finish_reason = None
    completion_tokens = None
    assembled_parts = []
    error_msg = None

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp, open(sse_log_path, "w", encoding="utf-8") as sse_f:
            t_headers = time.perf_counter()
            http_status = resp.status
            content_type = resp.headers.get("Content-Type", "")
            auto_selected_hdr = resp.headers.get("X-Auto-Selected-Model", "")
            auto_reason_hdr = resp.headers.get("X-Auto-Route-Reason", "")
            sse_f.write(f"# HTTP {http_status} | Content-Type: {content_type} | X-Auto-Selected-Model: {auto_selected_hdr} | X-Auto-Route-Reason: {auto_reason_hdr}\n")
            sse_f.write(f"# Headers received at +{t_headers - t_start:.4f}s\n\n")

            if "text/html" in content_type.lower():
                raw_err = resp.read(2048).decode("utf-8", errors="replace")
                sse_f.write(raw_err + "\n")
                raise RuntimeError(f"Received HTML response instead of SSE stream: {raw_err[:200]}")

            while True:
                raw_line = resp.readline()
                if not raw_line:
                    break
                now = time.perf_counter()
                rel_s = now - t_start
                line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
                if not line:
                    continue

                sse_f.write(f"[+{rel_s:0.4f}s] {line}\n")
                sse_f.flush()

                if not line.startswith("data:"):
                    continue

                sse_event_count += 1
                if t_first_sse_event is None:
                    t_first_sse_event = now

                data_str = line[len("data:"):].strip()
                if data_str == "[DONE]":
                    done_received = True
                    break

                try:
                    event_obj = json.loads(data_str)
                except json.JSONDecodeError as je:
                    error_msg = f"Invalid JSON in SSE data line: {je}"
                    break

                if returned_model is None and event_obj.get("model"):
                    returned_model = event_obj.get("model")

                usage_obj = event_obj.get("usage")
                if isinstance(usage_obj, dict) and usage_obj.get("completion_tokens") is not None:
                    completion_tokens = usage_obj.get("completion_tokens")

                choices = event_obj.get("choices") or []
                if choices:
                    choice0 = choices[0]
                    if choice0.get("finish_reason") is not None:
                        finish_reason = choice0.get("finish_reason")
                    delta = choice0.get("delta") or {}
                    delta_content = delta.get("content")
                    if isinstance(delta_content, str) and len(delta_content) > 0:
                        if t_first_content_token is None:
                            t_first_content_token = now
                        t_last_content_token = now
                        content_chunk_timestamps.append(now)
                        content_chunk_count += 1
                        assembled_parts.append(delta_content)

    except urllib.error.HTTPError as he:
        http_status = he.code
        err_body = ""
        try:
            err_body = he.read(2048).decode("utf-8", errors="replace")
        except Exception:
            pass
        error_msg = f"HTTPError {he.code}: {err_body.strip()}"
        with open(sse_log_path, "w", encoding="utf-8") as sse_f:
            sse_f.write(f"# ERROR: {error_msg}\n")
    except Exception as exc:
        error_msg = f"Stream exception: {exc}"
        with open(sse_log_path, "a", encoding="utf-8") as sse_f:
            sse_f.write(f"\n# EXCEPTION: {error_msg}\n")

    t_end = time.perf_counter()
    total_duration_s = t_end - t_start
    headers_latency_s = (t_headers - t_start) if t_headers is not None else None
    first_sse_s = (t_first_sse_event - t_start) if t_first_sse_event is not None else None
    ttft_s = (t_first_content_token - t_start) if t_first_content_token is not None else None
    stream_span_s = (
        (t_last_content_token - t_first_content_token)
        if (t_first_content_token is not None and t_last_content_token is not None)
        else 0.0
    )

    assembled_text = "".join(assembled_parts)
    char_count = len(assembled_text)

    # Validation checks
    failures = []
    if error_msg:
        failures.append(error_msg)
    if http_status != 200:
        failures.append(f"Expected HTTP 200, got {http_status}")
    if "text/event-stream" not in content_type.lower():
        failures.append(f"Expected Content-Type 'text/event-stream', got '{content_type}'")
    if returned_model != expected_model:
        failures.append(f"Expected returned model '{expected_model}', got '{returned_model}'")
    if tc["expected_auto_reason"] is not None:
        if auto_selected_hdr != expected_model:
            failures.append(f"Expected X-Auto-Selected-Model='{expected_model}', got '{auto_selected_hdr}'")
        if auto_reason_hdr != tc["expected_auto_reason"]:
            failures.append(f"Expected X-Auto-Route-Reason='{tc['expected_auto_reason']}', got '{auto_reason_hdr}'")
    if content_chunk_count == 0 or char_count == 0:
        failures.append("Stream contained zero non-empty content chunks")
    if ttft_s is None:
        failures.append("TTFT could not be measured (no non-empty content delta received)")
    if not done_received:
        failures.append("Did not receive final 'data: [DONE]' sentinel")

    passed = len(failures) == 0
    if not passed:
        overall_failed = True

    rec = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "case_id": case_id,
        "model_requested": tc["model_field"] or "<omitted (auto)>",
        "model_returned": returned_model,
        "auto_route_reason": auto_reason_hdr or "(explicit BBR->EPP)",
        "http_status": http_status,
        "content_type": content_type,
        "passed": passed,
        "failures": failures,
        "http_headers_latency_sec": round(headers_latency_s, 4) if headers_latency_s is not None else None,
        "first_sse_event_sec": round(first_sse_s, 4) if first_sse_s is not None else None,
        "ttft_sec": round(ttft_s, 4) if ttft_s is not None else None,
        "total_duration_sec": round(total_duration_s, 4),
        "generation_stream_span_sec": round(stream_span_s, 4),
        "sse_event_count": sse_event_count,
        "non_empty_content_chunks": content_chunk_count,
        "generated_characters": char_count,
        "completion_tokens_reported": completion_tokens,
        "finish_reason": finish_reason,
        "done_sentinel_received": done_received,
        "assembled_content": assembled_text,
    }
    results.append(rec)

    with open(json_out_path, "w", encoding="utf-8") as jf:
        json.dump(rec, jf, indent=2)

    print(f"  HTTP Status              : {http_status} ({content_type})")
    print(f"  Model (req -> resp)      : {rec['model_requested']} -> {returned_model}")
    print(f"  Route Reason             : {rec['auto_route_reason']}")
    print(f"  HTTP Headers Latency     : {rec['http_headers_latency_sec']} s")
    print(f"  First SSE Event (role)   : {rec['first_sse_event_sec']} s")
    print(f"  True TTFT (1st content)  : {rec['ttft_sec']} s")
    print(f"  Total Stream Duration    : {rec['total_duration_sec']} s")
    print(f"  Content Stream Span      : {rec['generation_stream_span_sec']} s")
    print(f"  Non-Empty Content Chunks : {content_chunk_count} (total SSE data events: {sse_event_count})")
    print(f"  Generated Characters     : {char_count}")
    print(f"  Received [DONE] Sentinel : {done_received}")
    print(f"  Assembled Response       : {assembled_text[:160]}")
    if passed:
        print(f"  [PASS] Streaming verification succeeded for '{case_id}'.")
    else:
        print(f"  [FAIL] Streaming verification failed for '{case_id}': {'; '.join(failures)}", file=sys.stderr)
    print("")

summary_path = os.path.join(out_dir, "summary.md")
with open(summary_path, "w", encoding="utf-8") as sf:
    sf.write("# Streaming Inference (SSE) Verification Summary\n\n")
    sf.write(f"- **Endpoint**: `{endpoint}`\n")
    sf.write(f"- **Max Tokens**: `{max_tokens}`\n\n")
    sf.write("> **Note on TTFT vs. HTTP First Byte**: `llama.cpp` emits an initial SSE event with `delta: {\"role\": \"assistant\", \"content\": null}` before the first token is decoded, or sends HTTP headers immediately. **True TTFT** below is measured from request submission until the **first non-empty `choices[0].delta.content` chunk** arrives.\n\n")
    sf.write("| Case | Requested `model` | Returned `model` | Route Reason | HTTP | HTTP Headers (s) | 1st SSE Event (s) | True TTFT (s) | Total Duration (s) | Content Chunks | Chars | `[DONE]` | Status |\n")
    sf.write("| :--- | :--- | :--- | :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: | :---: |\n")
    for r in results:
        status_str = "PASS" if r["passed"] else "FAIL"
        sf.write(
            f"| `{r['case_id']}` | `{r['model_requested']}` | `{r['model_returned']}` | `{r['auto_route_reason']}` | "
            f"`{r['http_status']}` | {r['http_headers_latency_sec']} | {r['first_sse_event_sec']} | **{r['ttft_sec']}** | "
            f"**{r['total_duration_sec']}** | {r['non_empty_content_chunks']} | {r['generated_characters']} | "
            f"`{r['done_sentinel_received']}` | **{status_str}** |\n"
        )
    sf.write("\n## Generated Content\n\n")
    for r in results:
        sf.write(f"### `{r['case_id']}` (`{r['model_requested']}` -> `{r['model_returned']}`)\n\n")
        sf.write(f"```text\n{r['assembled_content']}\n```\n\n")

print("============================================================")
print(f" Streaming Summary written to: {summary_path}")
print("============================================================")
with open(summary_path, "r", encoding="utf-8") as sf:
    print(sf.read())

if overall_failed:
    sys.exit(1)
PYEOF
