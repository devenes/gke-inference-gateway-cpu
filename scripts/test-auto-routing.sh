#!/usr/bin/env bash
set -euo pipefail

# End-to-End Public Gateway Verification for Rule-Based Automatic Model Routing.
# Tests both Mode A (Explicit model routing via BBR -> InferencePool -> EPP)
# and Mode B (Automatic rule-based model routing via fallback HTTPRoute -> auto-model-router)
# through the single public GKE Gateway endpoint.

NAMESPACE="${NAMESPACE:-default}"
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
RESULTS_DIR="${AUTO_ROUTE_OUT_DIR:-.results/auto-routing/${TIMESTAMP}}"
mkdir -p "${RESULTS_DIR}"

GW_IP="${GW_IP:-$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)}"
if [[ -z "${GW_IP}" ]]; then
  echo "ERROR: Gateway '${GATEWAY_NAME}' has no external IP address." >&2
  exit 1
fi

ENDPOINT="http://${GW_IP}/v1/chat/completions"

echo "=================================================================="
echo " Rule-Based Automatic Model Routing — Public Gateway E2E Test"
echo " Public Endpoint : ${ENDPOINT}"
echo " Results Dir     : ${RESULTS_DIR}"
echo "=================================================================="

# Verify no extra public LoadBalancer/NodePort services or Gateways exist
GW_COUNT="$(kubectl get gateway -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
PUBLIC_SVC_COUNT="$(kubectl get svc -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '$2 != "ClusterIP" {count++} END {print count+0}')"
if [[ "${GW_COUNT}" != "1" || "${PUBLIC_SVC_COUNT}" != "0" ]]; then
  echo "ERROR: Expected exactly 1 Gateway (got ${GW_COUNT}) and 0 non-ClusterIP Services (got ${PUBLIC_SVC_COUNT})." >&2
  exit 1
fi
echo "[OK] Verified single public Gateway (${GATEWAY_NAME}) and 0 external Services."

echo ""
echo "--- Step 0: Waiting for Regional External ALB & auto-model-router NEG convergence ---"
CONVERGED=0
for attempt in $(seq 1 36); do
  CODE_AUTO="$(curl -s -o "${RESULTS_DIR}/warmup_auto.json" -w '%{http_code}' --max-time 20 \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":8}' || echo "000")"
  if [[ "${CODE_AUTO}" == "200" ]]; then
    CONVERGED=1
    echo "[OK] Fallback route to auto-model-router converged (HTTP 200 on attempt ${attempt})."
    break
  fi
  echo "  [${attempt}/36] Waiting for Envoy fallback route & NEG health check (HTTP ${CODE_AUTO})..."
  sleep 5
done

if [[ "${CONVERGED}" -ne 1 ]]; then
  echo "ERROR: Fallback route to auto-model-router did not return HTTP 200 within timeout." >&2
  cat "${RESULTS_DIR}/warmup_auto.json" >&2 || true
  exit 1
fi

# Helper to execute a test case via Python so headers, status, JSON body, and routing metadata are captured cleanly
python3 - "${ENDPOINT}" "${RESULTS_DIR}" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

endpoint = sys.argv[1]
results_dir = sys.argv[2]

long_plain_text = (
    "Please provide a one-sentence summary of the following passage about urban gardening: "
    + (
        "Community gardens help neighborhoods share fresh produce, improve soil quality, "
        "foster social connections among residents, and create green spaces in dense cities. "
    ) * 8
)
assert len(long_plain_text) > 1200, f"Expected >1200 chars, got {len(long_plain_text)}"

test_cases = [
    {
        "id": "1_explicit_qwen",
        "title": "Explicit 'qwen-demo' (Mode A: BBR -> qwen-pool -> EPP)",
        "payload": {
            "model": "qwen-demo",
            "messages": [{"role": "user", "content": "State two benefits of containers in one short sentence."}],
            "max_tokens": 48,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "qwen-demo",
        "expect_auto_header": False,
        "expected_reason": None,
    },
    {
        "id": "2_explicit_smollm",
        "title": "Explicit 'smollm-demo' (Mode A: BBR -> smollm-pool -> EPP)",
        "payload": {
            "model": "smollm-demo",
            "messages": [{"role": "user", "content": "Write a Go program that parses JSON in one line."}],
            "max_tokens": 48,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "smollm-demo",
        "expect_auto_header": False,
        "expected_reason": None,
    },
    {
        "id": "3_auto_simple_omitted_model",
        "title": "Automatic Simple Prompt without 'model' -> smollm-demo (default-simple)",
        "payload": {
            "messages": [{"role": "user", "content": "Explain Kubernetes in two short sentences."}],
            "max_tokens": 48,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "smollm-demo",
        "expect_auto_header": True,
        "expected_reason": "default-simple",
    },
    {
        "id": "4_auto_code_omitted_model",
        "title": "Automatic Code Prompt without 'model' -> qwen-demo (code-request)",
        "payload": {
            "messages": [{"role": "user", "content": "Write a Go program that parses JSON and prints a field."}],
            "max_tokens": 64,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "qwen-demo",
        "expect_auto_header": True,
        "expected_reason": "code-request",
    },
    {
        "id": "5_auto_architecture_omitted_model",
        "title": "Automatic Architecture Trade-off Prompt without 'model' -> qwen-demo (architecture-request)",
        "payload": {
            "messages": [{"role": "user", "content": "Compare two Kubernetes networking architectures and explain the trade-offs briefly."}],
            "max_tokens": 64,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "qwen-demo",
        "expect_auto_header": True,
        "expected_reason": "architecture-request",
    },
    {
        "id": "6_auto_long_input_omitted_model",
        "title": f"Automatic Long Input ({len(long_plain_text)} chars > 1200) without 'model' -> qwen-demo (long-input)",
        "payload": {
            "messages": [{"role": "user", "content": long_plain_text}],
            "max_tokens": 40,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "qwen-demo",
        "expect_auto_header": True,
        "expected_reason": "long-input",
    },
    {
        "id": "7_auto_whitespace_model",
        "title": "Automatic Whitespace-Only 'model' ('   ') -> smollm-demo (default-simple)",
        "payload": {
            "model": "   ",
            "messages": [{"role": "user", "content": "What is DNS in one short sentence?"}],
            "max_tokens": 40,
            "temperature": 0.1,
        },
        "expected_status": 200,
        "expected_model": "smollm-demo",
        "expect_auto_header": True,
        "expected_reason": "default-simple",
    },
    {
        "id": "8_unknown_explicit_model_404",
        "title": "Unknown Explicit 'model' ('nonexistent-model') -> HTTP 404",
        "payload": {
            "model": "nonexistent-model",
            "messages": [{"role": "user", "content": "Hello"}],
            "max_tokens": 16,
        },
        "expected_status": 404,
        "expected_model": None,
        "expect_auto_header": False,
        "expected_reason": None,
    },
    {
        "id": "9_malformed_request_400",
        "title": "Malformed Request (wrong 'model' type) -> HTTP 400",
        "payload": {
            "model": 12345,
            "messages": [{"role": "user", "content": "Hello"}],
        },
        "expected_status": 400,
        "expected_model": None,
        "expect_auto_header": False,
        "expected_reason": None,
    },
]

summary_rows = []
failures = []

for tc in test_cases:
    print("")
    print("------------------------------------------------------------------")
    print(f"Case {tc['id']}: {tc['title']}")
    print("------------------------------------------------------------------")
    req_bytes = json.dumps(tc["payload"]).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=req_bytes,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.monotonic()
    status = 0
    headers = {}
    raw_resp = b""
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            status = resp.status
            headers = {k.lower(): v for k, v in resp.headers.items()}
            raw_resp = resp.read()
    except urllib.error.HTTPError as e:
        status = e.code
        headers = {k.lower(): v for k, v in e.headers.items()}
        raw_resp = e.read()
    latency_s = round(time.monotonic() - t0, 3)

    out_path = os.path.join(results_dir, f"{tc['id']}.json")
    with open(out_path, "wb") as f:
        f.write(raw_resp)

    auto_model_hdr = headers.get("x-auto-selected-model", "")
    auto_reason_hdr = headers.get("x-auto-route-reason", "")
    auto_mode_hdr = headers.get("x-auto-route-mode", "")

    returned_model = ""
    content_snippet = ""
    try:
        parsed = json.loads(raw_resp.decode("utf-8", errors="replace"))
        if isinstance(parsed, dict):
            returned_model = str(parsed.get("model", ""))
            choices = parsed.get("choices") or []
            if choices and isinstance(choices[0], dict):
                content_snippet = str((choices[0].get("message") or {}).get("content") or "").strip()
            elif "error" in parsed:
                content_snippet = json.dumps(parsed["error"])
    except Exception:
        content_snippet = raw_resp.decode("utf-8", errors="replace").strip()[:160]

    print(f"  HTTP Status            : {status} (latency: {latency_s:.3f}s)")
    print(f"  Returned JSON .model   : {returned_model or '<none>'}")
    print(f"  X-Auto-Selected-Model  : {auto_model_hdr or '<absent (explicit BBR->EPP route)>'}")
    print(f"  X-Auto-Route-Reason    : {auto_reason_hdr or '<absent (explicit BBR->EPP route)>'}")
    print(f"  Response Preview       : {content_snippet[:140]}")

    case_ok = True
    if status != tc["expected_status"]:
        case_ok = False
        failures.append(f"{tc['id']}: expected HTTP {tc['expected_status']}, got {status}")

    if tc["expected_model"] is not None:
        if returned_model != tc["expected_model"]:
            case_ok = False
            failures.append(f"{tc['id']}: expected JSON .model='{tc['expected_model']}', got '{returned_model}'")
        if not content_snippet:
            case_ok = False
            failures.append(f"{tc['id']}: empty completion content")

    if tc["expect_auto_header"]:
        if auto_model_hdr != tc["expected_model"]:
            case_ok = False
            failures.append(f"{tc['id']}: expected X-Auto-Selected-Model='{tc['expected_model']}', got '{auto_model_hdr}'")
        if auto_reason_hdr != tc["expected_reason"]:
            case_ok = False
            failures.append(f"{tc['id']}: expected X-Auto-Route-Reason='{tc['expected_reason']}', got '{auto_reason_hdr}'")
        if auto_mode_hdr != "auto":
            case_ok = False
            failures.append(f"{tc['id']}: expected X-Auto-Route-Mode='auto', got '{auto_mode_hdr}'")
    else:
        if tc["expected_status"] == 200 and auto_mode_hdr != "":
            case_ok = False
            failures.append(f"{tc['id']}: explicit request unexpectedly routed through auto-model-router (X-Auto-Route-Mode='{auto_mode_hdr}')")

    print(f"  Result                 : {'PASS' if case_ok else 'FAIL'}")
    summary_rows.append(
        {
            "id": tc["id"],
            "title": tc["title"],
            "status": status,
            "returned_model": returned_model or "-",
            "auto_model_hdr": auto_model_hdr or "(EPP direct)",
            "auto_reason_hdr": auto_reason_hdr or "(explicit BBR->EPP)",
            "latency_s": latency_s,
            "passed": case_ok,
            "preview": content_snippet.replace("\n", " ")[:90],
        }
    )

lines = [
    "# Rule-Based Automatic Model Routing — Public Gateway Verification Summary",
    "",
    f"- **Public Endpoint**: `{endpoint}`",
    "",
    "| Case | HTTP | JSON `.model` | `X-Auto-Selected-Model` | `X-Auto-Route-Reason` | Latency | Status | Response Preview |",
    "|---|---:|---|---|---|---:|---|---|",
]
for r in summary_rows:
    lines.append(
        f"| `{r['id']}` | `{r['status']}` | `{r['returned_model']}` | `{r['auto_model_hdr']}` | `{r['auto_reason_hdr']}` | {r['latency_s']:.3f}s | **{'PASS' if r['passed'] else 'FAIL'}** | {r['preview']} |"
    )
lines.append("")

summary_md = "\n".join(lines)
with open(os.path.join(results_dir, "summary.md"), "w", encoding="utf-8") as f:
    f.write(summary_md)

print("")
print(summary_md)

if failures:
    print("FAILURES:", file=sys.stderr)
    for fail in failures:
        print(f"  - {fail}", file=sys.stderr)
    sys.exit(1)
PY

echo "=================================================================="
echo " Routing Evidence from Cluster Logs"
echo "=================================================================="
echo "--- auto-model-router recent logs ---"
kubectl logs deployment/auto-model-router --tail=15 || true
echo ""
echo "--- qwen-pool-epp recent logs ---"
kubectl logs deployment/qwen-pool-epp --tail=10 || true
echo ""
echo "--- smollm-pool-epp recent logs ---"
kubectl logs deployment/smollm-pool-epp --tail=10 || true
echo ""
echo "=================================================================="
echo " ALL AUTOMATIC & EXPLICIT ROUTING E2E TESTS PASSED"
echo " Summary written to: ${RESULTS_DIR}/summary.md"
echo "=================================================================="
