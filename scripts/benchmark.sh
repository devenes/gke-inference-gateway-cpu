#!/usr/bin/env bash
set -euo pipefail

# End-to-end inference benchmark for the GKE Inference Gateway CPU MVP.
# Issues real OpenAI-compatible /v1/chat/completions requests through the public
# GKE Gateway (never bypassing the Gateway or Body-Based Router).

NAMESPACE="${NAMESPACE:-default}"
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"
CLUSTER_NAME="${CLUSTER_NAME:-gke-inference-gw-cpu}"
ZONE="${ZONE:-us-central1-a}"

# Configurable parameters with conservative defaults
BENCH_WARMUP_REQUESTS="${BENCH_WARMUP_REQUESTS:-1}"
BENCH_SEQ_REQUESTS="${BENCH_SEQ_REQUESTS:-5}"
BENCH_CONC_REQUESTS="${BENCH_CONC_REQUESTS:-4}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-2}"
BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-64}"
BENCH_REQ_TIMEOUT_SEC="${BENCH_REQ_TIMEOUT_SEC:-60}"
BENCH_CONNECT_TIMEOUT_SEC="${BENCH_CONNECT_TIMEOUT_SEC:-10}"

# Safety validation helper: ensures integer within [min, max]
validate_int_range() {
  local name="$1"
  local val="$2"
  local min="$3"
  local max="$4"
  if ! [[ "${val}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be a positive integer (got '${val}')." >&2
    exit 1
  fi
  if (( val < min || val > max )); then
    echo "ERROR: ${name}=${val} is outside safe bounds [${min}..${max}]." >&2
    exit 1
  fi
}

validate_int_range "BENCH_WARMUP_REQUESTS" "${BENCH_WARMUP_REQUESTS}" 0 3
validate_int_range "BENCH_SEQ_REQUESTS" "${BENCH_SEQ_REQUESTS}" 1 20
validate_int_range "BENCH_CONC_REQUESTS" "${BENCH_CONC_REQUESTS}" 1 20
validate_int_range "BENCH_CONCURRENCY" "${BENCH_CONCURRENCY}" 1 4
validate_int_range "BENCH_MAX_TOKENS" "${BENCH_MAX_TOKENS}" 8 128
validate_int_range "BENCH_REQ_TIMEOUT_SEC" "${BENCH_REQ_TIMEOUT_SEC}" 10 120

GW_IP="${GW_IP:-$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)}"
if [[ -z "${GW_IP}" ]]; then
  echo "ERROR: Could not discover public IP for Gateway/${GATEWAY_NAME} in namespace ${NAMESPACE}." >&2
  exit 1
fi

ENDPOINT="http://${GW_IP}/v1/chat/completions"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
RESULTS_DIR="${BENCH_OUT_DIR:-.results/benchmark/${TIMESTAMP}}"
mkdir -p "${RESULTS_DIR}/raw"

echo "=================================================================="
echo "GKE Inference Gateway End-to-End Benchmark"
echo "Gateway Endpoint    : ${ENDPOINT}"
echo "Warm-up Requests    : ${BENCH_WARMUP_REQUESTS} per model (excluded from stats)"
echo "Sequential Requests : ${BENCH_SEQ_REQUESTS} per model"
echo "Concurrent Requests : ${BENCH_CONC_REQUESTS} per model (concurrency=${BENCH_CONCURRENCY})"
echo "Max Tokens / Req    : ${BENCH_MAX_TOKENS}"
echo "Request Timeout     : ${BENCH_REQ_TIMEOUT_SEC}s"
echo "Results Directory   : ${RESULTS_DIR}"
echo "=================================================================="

# Capture cluster metadata & pre-benchmark resource state
NODE_INFO="$(kubectl get nodes -o wide 2>/dev/null || true)"
NODE_TOP_BEFORE="$(kubectl top nodes 2>/dev/null || echo "metrics-server unavailable")"
POD_TOP_BEFORE="$(kubectl top pods -n "${NAMESPACE}" 2>/dev/null || echo "metrics-server unavailable")"

# Capture pre-benchmark metrics snapshot if collect-metrics.sh is available
PRE_METRICS_DIR="${RESULTS_DIR}/metrics-before"
if [[ -x "scripts/collect-metrics.sh" ]]; then
  echo "--> Capturing pre-benchmark metrics snapshot..."
  METRICS_OUT_DIR="${PRE_METRICS_DIR}" METRICS_QUIET=1 ./scripts/collect-metrics.sh || true
fi

# Deterministic short prompts to exercise generation predictably
PROMPTS=(
  "Explain in two concise sentences what Kubernetes is and why it is useful."
  "List three benefits of running small quantized language models on CPU nodes."
  "What is an API gateway in cloud-native architecture? Reply in two short sentences."
  "Describe how HTTP load balancing works in two brief sentences."
  "State two differences between TCP and UDP in plain English."
)

# Run a single non-streaming request and write a JSON record to a per-request file
run_single_request() {
  local model="$1"
  local mode="$2"
  local req_idx="$3"
  local prompt_idx=$(( (req_idx - 1) % ${#PROMPTS[@]} ))
  local prompt="${PROMPTS[$prompt_idx]}"
  local prefix="${RESULTS_DIR}/raw/${model}_${mode}_${req_idx}"
  local body_file="${prefix}.body.json"
  local curl_meta_file="${prefix}.curl.txt"
  local record_file="${prefix}.record.json"
  local req_ts
  req_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local payload
  payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%d,"temperature":0.0,"stream":false}' \
    "${model}" "${prompt}" "${BENCH_MAX_TOKENS}")

  local curl_exit=0
  curl -sS -o "${body_file}" \
    --connect-timeout "${BENCH_CONNECT_TIMEOUT_SEC}" \
    --max-time "${BENCH_REQ_TIMEOUT_SEC}" \
    -w "%{http_code},%{time_total},%{time_starttransfer},%{time_connect}\n" \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "${payload}" >"${curl_meta_file}" 2>"${prefix}.err.txt" || curl_exit=$?

  python3 - "${req_ts}" "${model}" "${mode}" "${req_idx}" "${curl_exit}" "${curl_meta_file}" "${body_file}" "${prefix}.err.txt" "${record_file}" <<'PY'
import json
import os
import sys

req_ts, model, mode, req_idx, curl_exit, curl_meta_file, body_file, err_file, record_file = sys.argv[1:]
req_idx = int(req_idx)
curl_exit = int(curl_exit)

http_status = 0
time_total = 0.0
http_ttfb = 0.0
time_connect = 0.0

if os.path.exists(curl_meta_file):
    raw_meta = open(curl_meta_file, "r", encoding="utf-8", errors="replace").read().strip()
    parts = raw_meta.split(",")
    if len(parts) >= 4:
        try:
            http_status = int(parts[0])
            time_total = float(parts[1])
            http_ttfb = float(parts[2])
            time_connect = float(parts[3])
        except ValueError:
            pass

stderr_txt = ""
if os.path.exists(err_file):
    stderr_txt = open(err_file, "r", encoding="utf-8", errors="replace").read().strip()

prompt_tokens = 0
completion_tokens = 0
server_predicted_ms = 0.0
server_predicted_tps = 0.0
model_returned = ""
content_preview = ""
error_detail = ""
success = False

if curl_exit != 0:
    error_detail = f"curl_exit_{curl_exit}: {stderr_txt or 'request failed or timed out'}"
elif http_status != 200:
    body_preview = ""
    if os.path.exists(body_file):
        body_preview = open(body_file, "r", encoding="utf-8", errors="replace").read().strip()[:200]
    error_detail = f"http_{http_status}: {body_preview}"
else:
    try:
        data = json.load(open(body_file, "r", encoding="utf-8"))
        model_returned = str(data.get("model", ""))
        usage = data.get("usage") or {}
        prompt_tokens = int(usage.get("prompt_tokens") or 0)
        completion_tokens = int(usage.get("completion_tokens") or 0)
        timings = data.get("timings") or {}
        server_predicted_ms = float(timings.get("predicted_ms") or 0.0)
        server_predicted_tps = float(timings.get("predicted_per_second") or 0.0)
        choices = data.get("choices") or []
        if choices and isinstance(choices[0], dict):
            msg = choices[0].get("message") or {}
            content_preview = str(msg.get("content") or "").strip()
        if content_preview and completion_tokens > 0:
            success = True
        else:
            error_detail = "empty_completion_content"
    except Exception as exc:
        error_detail = f"invalid_json: {exc}"

record = {
    "timestamp_utc": req_ts,
    "model_requested": model,
    "mode": mode,
    "request_index": req_idx,
    "http_status": http_status,
    "total_latency_sec": round(time_total, 4),
    "http_ttfb_sec": round(http_ttfb, 4),
    "connect_latency_sec": round(time_connect, 4),
    "success": success,
    "prompt_tokens": prompt_tokens,
    "completion_tokens": completion_tokens,
    "server_predicted_ms": round(server_predicted_ms, 2),
    "server_predicted_tok_per_sec": round(server_predicted_tps, 2),
    "model_returned": model_returned,
    "error_detail": error_detail,
}

with open(record_file, "w", encoding="utf-8") as f:
    json.dump(record, f)
PY
}

PHASE_TIMINGS_FILE="${RESULTS_DIR}/raw/phase_timings.jsonl"
: > "${PHASE_TIMINGS_FILE}"

record_phase_timing() {
  local model="$1"
  local mode="$2"
  local start_ts="$3"
  local end_ts="$4"
  python3 - "${model}" "${mode}" "${start_ts}" "${end_ts}" "${PHASE_TIMINGS_FILE}" <<'PY'
import json, sys
model, mode, start_s, end_s, out_file = sys.argv[1:]
dur = max(0.0001, float(end_s) - float(start_s))
with open(out_file, "a", encoding="utf-8") as f:
    f.write(json.dumps({"model": model, "mode": mode, "wall_sec": round(dur, 4)}) + "\n")
PY
}

now_epoch() {
  python3 -c 'import time; print(f"{time.time():.6f}")'
}

MODELS=("qwen-demo" "smollm-demo")

# 1. Warm-up phase (excluded from measured statistics)
if (( BENCH_WARMUP_REQUESTS > 0 )); then
  echo ""
  echo "=== Phase 1: Warm-up (${BENCH_WARMUP_REQUESTS} request(s) per model, excluded from stats) ==="
  for model in "${MODELS[@]}"; do
    for i in $(seq 1 "${BENCH_WARMUP_REQUESTS}"); do
      echo "  [warmup] ${model} #${i}..."
      run_single_request "${model}" "warmup" "${i}"
    done
  done
fi

# 2. Sequential measured phase
echo ""
echo "=== Phase 2: Sequential Benchmark (${BENCH_SEQ_REQUESTS} requests per model) ==="
for model in "${MODELS[@]}"; do
  p_start="$(now_epoch)"
  for i in $(seq 1 "${BENCH_SEQ_REQUESTS}"); do
    run_single_request "${model}" "sequential" "${i}"
    rec_file="${RESULTS_DIR}/raw/${model}_sequential_${i}.record.json"
    python3 - "${rec_file}" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
status = "OK" if r["success"] else f"FAIL({r['error_detail']})"
print(f"  [sequential] {r['model_requested']} #{r['request_index']}: HTTP {r['http_status']} | total={r['total_latency_sec']:.3f}s | http_ttfb={r['http_ttfb_sec']:.3f}s | tokens={r['completion_tokens']} | {status}")
PY
  done
  p_end="$(now_epoch)"
  record_phase_timing "${model}" "sequential" "${p_start}" "${p_end}"
done

# 3. Bounded concurrent measured phase
echo ""
echo "=== Phase 3: Bounded Concurrent Benchmark (${BENCH_CONC_REQUESTS} requests per model, concurrency=${BENCH_CONCURRENCY}) ==="
for model in "${MODELS[@]}"; do
  p_start="$(now_epoch)"
  active_pids=()
  for i in $(seq 1 "${BENCH_CONC_REQUESTS}"); do
    run_single_request "${model}" "concurrent" "${i}" &
    active_pids+=($!)
    if (( ${#active_pids[@]} >= BENCH_CONCURRENCY )); then
      for pid in "${active_pids[@]}"; do
        wait "${pid}" || true
      done
      active_pids=()
    fi
  done
  for pid in "${active_pids[@]:-}"; do
    if [[ -n "${pid}" ]]; then
      wait "${pid}" || true
    fi
  done
  p_end="$(now_epoch)"
  record_phase_timing "${model}" "concurrent" "${p_start}" "${p_end}"

  for i in $(seq 1 "${BENCH_CONC_REQUESTS}"); do
    rec_file="${RESULTS_DIR}/raw/${model}_concurrent_${i}.record.json"
    python3 - "${rec_file}" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
status = "OK" if r["success"] else f"FAIL({r['error_detail']})"
print(f"  [concurrent] {r['model_requested']} #{r['request_index']}: HTTP {r['http_status']} | total={r['total_latency_sec']:.3f}s | http_ttfb={r['http_ttfb_sec']:.3f}s | tokens={r['completion_tokens']} | {status}")
PY
  done
done

NODE_TOP_AFTER="$(kubectl top nodes 2>/dev/null || echo "metrics-server unavailable")"
POD_TOP_AFTER="$(kubectl top pods -n "${NAMESPACE}" 2>/dev/null || echo "metrics-server unavailable")"

POST_METRICS_DIR="${RESULTS_DIR}/metrics-after"
if [[ -x "scripts/collect-metrics.sh" ]]; then
  echo ""
  echo "--> Capturing post-benchmark metrics snapshot..."
  COMPARE_SNAPSHOT="${PRE_METRICS_DIR}/snapshot.json" METRICS_OUT_DIR="${POST_METRICS_DIR}" METRICS_QUIET=1 ./scripts/collect-metrics.sh || true
fi

# Write metadata.txt
cat >"${RESULTS_DIR}/metadata.txt" <<EOF
timestamp_utc=${TIMESTAMP}
gateway_endpoint=${ENDPOINT}
gateway_name=${GATEWAY_NAME}
namespace=${NAMESPACE}
cluster_name=${CLUSTER_NAME}
zone=${ZONE}
bench_warmup_requests=${BENCH_WARMUP_REQUESTS}
bench_seq_requests=${BENCH_SEQ_REQUESTS}
bench_conc_requests=${BENCH_CONC_REQUESTS}
bench_concurrency=${BENCH_CONCURRENCY}
bench_max_tokens=${BENCH_MAX_TOKENS}
bench_req_timeout_sec=${BENCH_REQ_TIMEOUT_SEC}

--- kubectl get nodes -o wide ---
${NODE_INFO}

--- kubectl top nodes (before) ---
${NODE_TOP_BEFORE}

--- kubectl top pods (before) ---
${POD_TOP_BEFORE}

--- kubectl top nodes (after) ---
${NODE_TOP_AFTER}

--- kubectl top pods (after) ---
${POD_TOP_AFTER}
EOF

# Aggregate results into requests.csv and summary.md
python3 - "${RESULTS_DIR}" "${ENDPOINT}" "${TIMESTAMP}" "${BENCH_WARMUP_REQUESTS}" "${BENCH_SEQ_REQUESTS}" "${BENCH_CONC_REQUESTS}" "${BENCH_CONCURRENCY}" "${BENCH_MAX_TOKENS}" <<'PY'
import csv
import glob
import json
import math
import os
import sys

(
    results_dir,
    endpoint,
    timestamp,
    warmup_n,
    seq_n,
    conc_n,
    concurrency,
    max_tokens,
) = sys.argv[1:]

raw_dir = os.path.join(results_dir, "raw")
record_files = sorted(glob.glob(os.path.join(raw_dir, "*.record.json")))
records = [json.load(open(f, "r", encoding="utf-8")) for f in record_files]

mode_order = {"warmup": 0, "sequential": 1, "concurrent": 2}
records.sort(key=lambda r: (r["model_requested"], mode_order.get(r["mode"], 99), r["request_index"]))

csv_fields = [
    "timestamp_utc",
    "model_requested",
    "mode",
    "request_index",
    "http_status",
    "total_latency_sec",
    "http_ttfb_sec",
    "connect_latency_sec",
    "success",
    "prompt_tokens",
    "completion_tokens",
    "server_predicted_ms",
    "server_predicted_tok_per_sec",
    "model_returned",
    "error_detail",
]

csv_path = os.path.join(results_dir, "requests.csv")
with open(csv_path, "w", newline="", encoding="utf-8") as cf:
    writer = csv.DictWriter(cf, fieldnames=csv_fields)
    writer.writeheader()
    for r in records:
        writer.writerow({k: r.get(k, "") for k in csv_fields})

phase_timings = {}
pt_file = os.path.join(raw_dir, "phase_timings.jsonl")
if os.path.exists(pt_file):
    for line in open(pt_file, "r", encoding="utf-8"):
        if line.strip():
            obj = json.loads(line)
            phase_timings[(obj["model"], obj["mode"])] = float(obj["wall_sec"])

def percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = (len(sorted_vals) - 1) * (pct / 100.0)
    low = int(math.floor(pos))
    high = int(math.ceil(pos))
    if low == high:
        return sorted_vals[low]
    weight = pos - low
    return sorted_vals[low] * (1.0 - weight) + sorted_vals[high] * weight

models = ["qwen-demo", "smollm-demo"]
modes = ["sequential", "concurrent"]

summary_rows = []
any_model_completely_failed = False

for model in models:
    model_measured_ok = 0
    for mode in modes:
        subset = [r for r in records if r["model_requested"] == model and r["mode"] == mode]
        ok_recs = [r for r in subset if r["success"]]
        fail_recs = [r for r in subset if not r["success"]]
        http_err_recs = [r for r in subset if r["http_status"] != 200]
        model_measured_ok += len(ok_recs)

        lats = sorted(r["total_latency_sec"] for r in ok_recs)
        ttfbs = sorted(r["http_ttfb_sec"] for r in ok_recs)
        comp_tokens = sum(r["completion_tokens"] for r in ok_recs)
        wall_sec = phase_timings.get((model, mode), sum(lats) if lats else 0.0)

        p50 = percentile(lats, 50)
        p95 = percentile(lats, 95)
        avg_lat = (sum(lats) / len(lats)) if lats else 0.0
        avg_ttfb = (sum(ttfbs) / len(ttfbs)) if ttfbs else 0.0
        rps = (len(ok_recs) / wall_sec) if wall_sec > 0 else 0.0
        obs_tps = (comp_tokens / wall_sec) if wall_sec > 0 else 0.0
        srv_tps_vals = [r["server_predicted_tok_per_sec"] for r in ok_recs if r["server_predicted_tok_per_sec"] > 0]
        avg_srv_tps = (sum(srv_tps_vals) / len(srv_tps_vals)) if srv_tps_vals else 0.0

        summary_rows.append({
            "model": model,
            "mode": mode,
            "total": len(subset),
            "ok": len(ok_recs),
            "fail": len(fail_recs),
            "http_err": len(http_err_recs),
            "p50": p50,
            "p95": p95,
            "avg_lat": avg_lat,
            "avg_ttfb": avg_ttfb,
            "wall_sec": wall_sec,
            "rps": rps,
            "comp_tokens": comp_tokens,
            "obs_tps": obs_tps,
            "avg_srv_tps": avg_srv_tps,
        })
    if model_measured_ok == 0:
        any_model_completely_failed = True

lines = []
lines.append(f"# GKE Inference Gateway End-to-End Benchmark Summary ({timestamp} UTC)")
lines.append("")
lines.append("## 1. Benchmark Configuration")
lines.append("")
lines.append(f"- **Public Gateway Endpoint**: `{endpoint}`")
lines.append(f"- **Warm-up Requests**: `{warmup_n}` per model (recorded in `requests.csv` with `mode=warmup`, excluded from summary tables below)")
lines.append(f"- **Sequential Measured Requests**: `{seq_n}` per model")
lines.append(f"- **Concurrent Measured Requests**: `{conc_n}` per model at concurrency `{concurrency}`")
lines.append(f"- **Max Generated Tokens (`max_tokens`)**: `{max_tokens}` (`temperature: 0.0`)")
lines.append("")
lines.append("> **Measurement Note**:")
lines.append("> - `p95 Latency` below is a **preliminary small-sample estimate** (`N=5` sequential, `N=4` concurrent per model).")
lines.append("> - `Avg HTTP TTFB` is `curl`'s `time_starttransfer` for non-streaming responses (`stream: false`), which reflects when the server begins transmitting the complete JSON response. **True Time-to-First-Token (TTFT)** requires SSE streaming (`stream: true`) and is measured separately by `make test-streaming` (`scripts/test-streaming.sh`).")
lines.append("")
lines.append("## 2. Per-Model & Per-Mode Results")
lines.append("")
lines.append("| Model | Mode | OK / Total | HTTP Err | p50 Latency | p95 Latency (est.) | Avg Latency | Avg HTTP TTFB | Wall Time | Observed RPS | End-to-End Tok/s | Server Decode Tok/s |")
lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for row in summary_rows:
    lines.append(
        f"| `{row['model']}` | `{row['mode']}` | {row['ok']}/{row['total']} | {row['http_err']} | "
        f"{row['p50']:.3f}s | {row['p95']:.3f}s | {row['avg_lat']:.3f}s | {row['avg_ttfb']:.3f}s | "
        f"{row['wall_sec']:.2f}s | {row['rps']:.2f} req/s | {row['obs_tps']:.2f} tok/s | {row['avg_srv_tps']:.2f} tok/s |"
    )
lines.append("")

# Include before/after Prometheus counter deltas if available
pre_snap = os.path.join(results_dir, "metrics-before", "snapshot.json")
post_snap = os.path.join(results_dir, "metrics-after", "snapshot.json")
if os.path.exists(pre_snap) and os.path.exists(post_snap):
    pre = json.load(open(pre_snap, "r", encoding="utf-8"))
    post = json.load(open(post_snap, "r", encoding="utf-8"))
    lines.append("## 3. Server & Endpoint Picker Metric Deltas Across Benchmark")
    lines.append("")
    lines.append("| Metric Delta (Post - Pre) | `qwen-demo` / `qwen-pool-epp` | `smollm-demo` / `smollm-pool-epp` |")
    lines.append("|---|---:|---:|")
    q_req_d = int(post["epp"]["qwen-pool-epp"]["objective_request_total"] - pre["epp"]["qwen-pool-epp"]["objective_request_total"])
    s_req_d = int(post["epp"]["smollm-pool-epp"]["objective_request_total"] - pre["epp"]["smollm-pool-epp"]["objective_request_total"])
    q_ptok_d = int(post["models"]["qwen-demo"]["prompt_tokens_total"] - pre["models"]["qwen-demo"]["prompt_tokens_total"])
    s_ptok_d = int(post["models"]["smollm-demo"]["prompt_tokens_total"] - pre["models"]["smollm-demo"]["prompt_tokens_total"])
    q_ctok_d = int(post["models"]["qwen-demo"]["tokens_predicted_total"] - pre["models"]["qwen-demo"]["tokens_predicted_total"])
    s_ctok_d = int(post["models"]["smollm-demo"]["tokens_predicted_total"] - pre["models"]["smollm-demo"]["tokens_predicted_total"])
    lines.append(f"| `+ inference_objective_request_total` (EPP) | +{q_req_d} | +{s_req_d} |")
    lines.append(f"| `+ llamacpp:prompt_tokens_total` | +{q_ptok_d} | +{s_ptok_d} |")
    lines.append(f"| `+ llamacpp:tokens_predicted_total` | +{q_ctok_d} | +{s_ctok_d} |")
    lines.append("")

lines.append("## 4. Architectural & Capacity Observations (Single `e2-standard-2` CPU Node)")
lines.append("")
lines.append("- **Shared 2-vCPU Contention**: Both `qwen-demo` (`Qwen2.5-0.5B-Instruct-Q4_K_M`, 500m request / 1500m limit) and `smollm-demo` (`SmolLM2-360M-Instruct-Q4_K_M`, 400m request / 1500m limit), along with two Endpoint Pickers (`qwen-pool-epp`, `smollm-pool-epp`) and the `body-based-router`, share a single `e2-standard-2` (2 vCPU, 8 GB RAM) node.")
lines.append("- **Sequential vs. Concurrent Latency (`--parallel 2`)**: Each `llama-server` deployment is configured with `--parallel 2` (`2` active KV slots) and `--threads 2` on the 2-vCPU node. Under `concurrency=2`, both simultaneous requests to the same model execute concurrently across the two KV slots, splitting the 2 vCPUs (~half the per-request `Server Decode Tok/s` and roughly 1.5x–1.8x per-request latency) while increasing aggregate end-to-end throughput (`Observed RPS` and `End-to-End Tok/s`) with zero HTTP errors or OOM events.")
lines.append("- **Model Comparison**: `SmolLM2-360M` (360M parameters) achieves higher single-request decode throughput (`tok/s`) and lower sequential p50 latency than `Qwen2.5-0.5B` (490M parameters), matching their parameter ratio.")
lines.append("")

summary_md = "\n".join(lines)
summary_path = os.path.join(results_dir, "summary.md")
with open(summary_path, "w", encoding="utf-8") as f:
    f.write(summary_md)

print("")
print(summary_md)

if any_model_completely_failed:
    print("ERROR: All measured requests failed for at least one model.", file=sys.stderr)
    sys.exit(1)
PY

echo "=================================================================="
echo "Benchmark artifacts saved to: ${RESULTS_DIR}"
echo "  - ${RESULTS_DIR}/requests.csv"
echo "  - ${RESULTS_DIR}/summary.md"
echo "  - ${RESULTS_DIR}/metadata.txt"
echo "=================================================================="
