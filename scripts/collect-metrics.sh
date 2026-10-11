#!/usr/bin/env bash
set -euo pipefail

# Lightweight Prometheus metrics collector for GKE Inference Gateway CPU MVP.
# Scrapes both llama.cpp model servers and both Gateway API Inference Extension
# Endpoint Pickers (EPPs) via temporary local port-forwards (with guaranteed cleanup)
# and writes raw scrapes + a parsed Markdown summary to .results/metrics/<timestamp>/.

NAMESPACE="${NAMESPACE:-default}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
RESULTS_DIR="${METRICS_OUT_DIR:-.results/metrics/${TIMESTAMP}}"
COMPARE_SNAPSHOT="${COMPARE_SNAPSHOT:-}"
QUIET="${METRICS_QUIET:-0}"

mkdir -p "${RESULTS_DIR}"

PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

log() {
  if [[ "${QUIET}" != "1" ]]; then
    echo "$@"
  fi
}

scrape_service_metrics() {
  local svc_name="$1"
  local remote_port="$2"
  local local_port="$3"
  local out_file="$4"
  local pf_log="${RESULTS_DIR}/.pf-${svc_name}.log"

  log "--> Scraping ${svc_name}:${remote_port}/metrics (via 127.0.0.1:${local_port})..."
  kubectl port-forward -n "${NAMESPACE}" "svc/${svc_name}" "${local_port}:${remote_port}" >"${pf_log}" 2>&1 &
  local pf_pid=$!
  PF_PIDS+=("${pf_pid}")

  local ready=0
  for _ in $(seq 1 25); do
    if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
      break
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${local_port}/metrics" -o "${out_file}" 2>/dev/null; then
      if [[ -s "${out_file}" ]]; then
        ready=1
        break
      fi
    fi
    sleep 0.3
  done

  kill "${pf_pid}" >/dev/null 2>&1 || true
  wait "${pf_pid}" 2>/dev/null || true
  rm -f "${pf_log}"

  if [[ "${ready}" -ne 1 ]]; then
    echo "ERROR: Failed to scrape metrics from svc/${svc_name}:${remote_port}" >&2
    return 1
  fi
}

log "=================================================================="
log "Collecting Model & Endpoint Picker Metrics -> ${RESULTS_DIR}"
log "=================================================================="

scrape_service_metrics "qwen-demo" "8080" "18081" "${RESULTS_DIR}/qwen.metrics"
scrape_service_metrics "smollm-demo" "8080" "18082" "${RESULTS_DIR}/smollm.metrics"
scrape_service_metrics "qwen-pool-epp" "9090" "19091" "${RESULTS_DIR}/qwen-epp.metrics"
scrape_service_metrics "smollm-pool-epp" "9090" "19092" "${RESULTS_DIR}/smollm-epp.metrics"

NODE_TOP="$(kubectl top nodes 2>/dev/null || echo "metrics-server unavailable")"
POD_TOP="$(kubectl top pods -n "${NAMESPACE}" 2>/dev/null || echo "metrics-server unavailable")"

python3 - "${RESULTS_DIR}" "${TIMESTAMP}" "${COMPARE_SNAPSHOT}" "${NODE_TOP}" "${POD_TOP}" <<'PY'
import json
import os
import re
import sys

results_dir = sys.argv[1]
timestamp = sys.argv[2]
compare_snapshot_path = sys.argv[3]
node_top = sys.argv[4]
pod_top = sys.argv[5]

LINE_RE = re.compile(
    r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|NaN|[+-]?Inf)$'
)

def parse_prom_file(path):
    metrics = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            name, labels_str, val_str = m.groups()
            labels = {}
            if labels_str:
                for part in re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="([^"]*)"', labels_str):
                    labels[part[0]] = part[1]
            try:
                val = float(val_str)
            except ValueError:
                continue
            metrics.append({"name": name, "labels": labels, "value": val})
    return metrics

def get_single(metrics, name, label_filter=None, default=0.0):
    total = 0.0
    found = False
    for item in metrics:
        if item["name"] != name:
            continue
        if label_filter:
            if any(item["labels"].get(k) != v for k, v in label_filter.items()):
                continue
        total += item["value"]
        found = True
    return total if found else default

def extract_llamacpp(path):
    m = parse_prom_file(path)
    p_tok = get_single(m, "llamacpp:prompt_tokens_total")
    p_sec = get_single(m, "llamacpp:prompt_seconds_total")
    c_tok = get_single(m, "llamacpp:tokens_predicted_total")
    c_sec = get_single(m, "llamacpp:tokens_predicted_seconds_total")
    return {
        "prompt_tokens_total": p_tok,
        "prompt_tokens_cached_total": get_single(m, "llamacpp:prompt_tokens_cached_total"),
        "tokens_predicted_total": c_tok,
        "prompt_seconds_total": p_sec,
        "tokens_predicted_seconds_total": c_sec,
        "cumulative_prompt_tps": (p_tok / p_sec) if p_sec > 0 else 0.0,
        "cumulative_decode_tps": (c_tok / c_sec) if c_sec > 0 else 0.0,
        "prompt_tokens_seconds": get_single(m, "llamacpp:prompt_tokens_seconds"),
        "predicted_tokens_seconds": get_single(m, "llamacpp:predicted_tokens_seconds"),
        "requests_processing": get_single(m, "llamacpp:requests_processing"),
        "requests_deferred": get_single(m, "llamacpp:requests_deferred"),
        "n_decode_total": get_single(m, "llamacpp:n_decode_total"),
        "n_busy_slots_per_decode": get_single(m, "llamacpp:n_busy_slots_per_decode"),
        "n_tokens_max": get_single(m, "llamacpp:n_tokens_max"),
    }

def extract_epp(path):
    m = parse_prom_file(path)
    build_info = {}
    for item in m:
        if item["name"] == "inference_extension_info":
            build_info = item["labels"]
            break

    req_count = get_single(m, "inference_objective_request_duration_seconds_count")
    req_sum = get_single(m, "inference_objective_request_duration_seconds_sum")
    avg_dur = (req_sum / req_count) if req_count > 0 else 0.0

    sched_count = get_single(m, "inference_extension_scheduler_e2e_duration_seconds_count")
    sched_sum = get_single(m, "inference_extension_scheduler_e2e_duration_seconds_sum")
    sched_avg_ms = ((sched_sum / sched_count) * 1000.0) if sched_count > 0 else 0.0

    tpot_count = get_single(m, "inference_objective_normalized_time_per_output_token_seconds_count")
    tpot_sum = get_single(m, "inference_objective_normalized_time_per_output_token_seconds_sum")
    tpot_avg_ms = ((tpot_sum / tpot_count) * 1000.0) if tpot_count > 0 else 0.0

    plugins = {}
    for item in m:
        if item["name"] == "inference_extension_plugin_duration_seconds_sum":
            ptype = item["labels"].get("plugin_type", "unknown")
            plugins.setdefault(ptype, {})["sum"] = item["value"]
        elif item["name"] == "inference_extension_plugin_duration_seconds_count":
            ptype = item["labels"].get("plugin_type", "unknown")
            plugins.setdefault(ptype, {})["count"] = item["value"]

    plugin_summary = {}
    for ptype, pvals in sorted(plugins.items()):
        c = pvals.get("count", 0.0)
        s = pvals.get("sum", 0.0)
        plugin_summary[ptype] = {
            "count": int(c),
            "avg_ms": round((s / c) * 1000.0, 4) if c > 0 else 0.0,
        }

    return {
        "build_ref": build_info.get("build_ref", "unknown"),
        "ready_pods": get_single(m, "inference_pool_ready_pods"),
        "avg_queue_size": get_single(m, "inference_pool_average_queue_size"),
        "avg_running_requests": get_single(m, "inference_pool_average_running_requests"),
        "avg_kv_cache_utilization": get_single(m, "inference_pool_average_kv_cache_utilization"),
        "per_pod_queue_size": get_single(m, "inference_pool_per_pod_queue_size"),
        "scheduler_attempts_total": get_single(m, "inference_extension_scheduler_attempts_total"),
        "scheduler_e2e_avg_ms": sched_avg_ms,
        "objective_request_total": get_single(m, "inference_objective_request_total"),
        "objective_request_error_total": get_single(m, "inference_objective_request_error_total"),
        "objective_running_requests": get_single(m, "inference_objective_running_requests"),
        "objective_duration_count": req_count,
        "objective_duration_sum_sec": req_sum,
        "objective_avg_duration_sec": avg_dur,
        "objective_input_tokens_sum": get_single(m, "inference_objective_input_tokens_sum"),
        "objective_output_tokens_sum": get_single(m, "inference_objective_output_tokens_sum"),
        "objective_tpot_avg_ms": tpot_avg_ms,
        "objective_response_bytes_sum": get_single(m, "inference_objective_response_sizes_sum"),
        "plugins": plugin_summary,
    }

snapshot = {
    "timestamp_utc": timestamp,
    "models": {
        "qwen-demo": extract_llamacpp(os.path.join(results_dir, "qwen.metrics")),
        "smollm-demo": extract_llamacpp(os.path.join(results_dir, "smollm.metrics")),
    },
    "epp": {
        "qwen-pool-epp": extract_epp(os.path.join(results_dir, "qwen-epp.metrics")),
        "smollm-pool-epp": extract_epp(os.path.join(results_dir, "smollm-epp.metrics")),
    },
}

snapshot_path = os.path.join(results_dir, "snapshot.json")
with open(snapshot_path, "w", encoding="utf-8") as f:
    json.dump(snapshot, f, indent=2)

q_m = snapshot["models"]["qwen-demo"]
s_m = snapshot["models"]["smollm-demo"]
q_e = snapshot["epp"]["qwen-pool-epp"]
s_e = snapshot["epp"]["smollm-pool-epp"]

lines = []
lines.append(f"# GKE Inference Gateway Metrics Summary ({timestamp} UTC)")
lines.append("")
lines.append("## 1. `llama.cpp` Model Server Metrics (`:8080/metrics`)")
lines.append("")
lines.append("| Metric (`llamacpp:*`) | `qwen-demo` (Qwen2.5-0.5B) | `smollm-demo` (SmolLM2-360M) | Description |")
lines.append("|---|---:|---:|---|")
lines.append(f"| `prompt_tokens_total` | {int(q_m['prompt_tokens_total'])} | {int(s_m['prompt_tokens_total'])} | Cumulative non-cached prompt tokens evaluated |")
lines.append(f"| `prompt_tokens_cached_total` | {int(q_m['prompt_tokens_cached_total'])} | {int(s_m['prompt_tokens_cached_total'])} | Cumulative prompt tokens reused from LCP prefix cache |")
lines.append(f"| `tokens_predicted_total` | {int(q_m['tokens_predicted_total'])} | {int(s_m['tokens_predicted_total'])} | Cumulative generated (completion) tokens |")
lines.append(f"| `prompt_seconds_total` | {q_m['prompt_seconds_total']:.3f}s | {s_m['prompt_seconds_total']:.3f}s | Cumulative prompt evaluation time |")
lines.append(f"| `tokens_predicted_seconds_total` | {q_m['tokens_predicted_seconds_total']:.3f}s | {s_m['tokens_predicted_seconds_total']:.3f}s | Cumulative token generation (decode) time |")
lines.append(f"| Derived `prompt_tokens_total / prompt_seconds_total` | {q_m['cumulative_prompt_tps']:.2f} tok/s | {s_m['cumulative_prompt_tps']:.2f} tok/s | Cumulative average prompt evaluation throughput |")
lines.append(f"| Derived `tokens_predicted_total / tokens_predicted_seconds_total` | {q_m['cumulative_decode_tps']:.2f} tok/s | {s_m['cumulative_decode_tps']:.2f} tok/s | Cumulative average token generation (decode) throughput |")
lines.append(f"| `requests_processing` | {int(q_m['requests_processing'])} | {int(s_m['requests_processing'])} | Active requests currently processing (instantaneous gauge) |")
lines.append(f"| `requests_deferred` | {int(q_m['requests_deferred'])} | {int(s_m['requests_deferred'])} | Queued/deferred requests waiting for a slot |")
lines.append(f"| `n_decode_total` | {int(q_m['n_decode_total'])} | {int(s_m['n_decode_total'])} | Total `llama_decode()` forward-pass calls |")
lines.append(f"| `n_busy_slots_per_decode` | {q_m['n_busy_slots_per_decode']:.2f} | {s_m['n_busy_slots_per_decode']:.2f} | Average busy parallel slots per decode step |")
lines.append(f"| `n_tokens_max` | {int(q_m['n_tokens_max'])} | {int(s_m['n_tokens_max'])} | Largest observed sequence length (prompt + completion) |")
lines.append("")

lines.append("## 2. Endpoint Picker (EPP) Metrics (`:9090/metrics`)")
lines.append("")
lines.append("| Metric (`inference_*`) | `qwen-pool-epp` | `smollm-pool-epp` | Description |")
lines.append("|---|---:|---:|---|")
lines.append(f"| `inference_extension_info` (`build_ref`) | `{q_e['build_ref']}` | `{s_e['build_ref']}` | Gateway API Inference Extension build version |")
lines.append(f"| `inference_pool_ready_pods` | {int(q_e['ready_pods'])} | {int(s_e['ready_pods'])} | Ready model server pods in the `InferencePool` |")
lines.append(f"| `inference_extension_scheduler_attempts_total` | {int(q_e['scheduler_attempts_total'])} | {int(s_e['scheduler_attempts_total'])} | Total successful EPP pod scheduling decisions |")
lines.append(f"| `inference_extension_scheduler_e2e_duration_seconds` (avg) | {q_e['scheduler_e2e_avg_ms']:.3f} ms | {s_e['scheduler_e2e_avg_ms']:.3f} ms | Mean EPP end-to-end scheduling latency |")
lines.append(f"| `inference_objective_request_total` | {int(q_e['objective_request_total'])} | {int(s_e['objective_request_total'])} | Total requests routed through this `InferencePool` |")
lines.append(f"| `inference_objective_request_error_total` | {int(q_e['objective_request_error_total'])} | {int(s_e['objective_request_error_total'])} | Total errored requests observed by EPP |")
lines.append(f"| `inference_objective_running_requests` | {int(q_e['objective_running_requests'])} | {int(s_e['objective_running_requests'])} | In-flight requests currently tracked by EPP |")
lines.append(f"| `inference_objective_request_duration_seconds` (avg) | {q_e['objective_avg_duration_sec']:.3f}s (n={int(q_e['objective_duration_count'])}) | {s_e['objective_avg_duration_sec']:.3f}s (n={int(s_e['objective_duration_count'])}) | Mean end-to-end request duration observed by EPP |")
lines.append(f"| `inference_objective_input_tokens_sum` | {int(q_e['objective_input_tokens_sum'])} | {int(s_e['objective_input_tokens_sum'])} | Cumulative input tokens observed by EPP (non-streaming responses) |")
lines.append(f"| `inference_objective_output_tokens_sum` | {int(q_e['objective_output_tokens_sum'])} | {int(s_e['objective_output_tokens_sum'])} | Cumulative output tokens observed by EPP (non-streaming responses) |")
lines.append(f"| `inference_objective_normalized_time_per_output_token_seconds` (avg) | {q_e['objective_tpot_avg_ms']:.2f} ms/tok | {s_e['objective_tpot_avg_ms']:.2f} ms/tok | Mean normalized time per output token observed by EPP |")
lines.append(f"| `inference_objective_response_sizes_sum` | {int(q_e['objective_response_bytes_sum'])} B | {int(s_e['objective_response_bytes_sum'])} B | Cumulative HTTP response payload size in bytes |")
lines.append(f"| `inference_pool_average_running_requests` | {q_e['avg_running_requests']:.2f} | {s_e['avg_running_requests']:.2f} | Pool average running requests scraped from backends |")
lines.append(f"| `inference_pool_average_queue_size` | {q_e['avg_queue_size']:.2f} | {s_e['avg_queue_size']:.2f} | Pool average waiting queue size |")
lines.append(f"| `inference_pool_average_kv_cache_utilization` | {q_e['avg_kv_cache_utilization']:.4f} | {s_e['avg_kv_cache_utilization']:.4f} | Pool average KV cache utilization metric (vLLM-format gauge) |")
lines.append("")

lines.append("### EPP Scheduling Plugin Latency (`inference_extension_plugin_duration_seconds`)")
lines.append("")
lines.append("| Plugin Type | `qwen-pool-epp` Calls | `qwen-pool-epp` Avg (ms) | `smollm-pool-epp` Calls | `smollm-pool-epp` Avg (ms) |")
lines.append("|---|---:|---:|---:|---:|")
all_plugins = sorted(set(q_e["plugins"].keys()) | set(s_e["plugins"].keys()))
for ptype in all_plugins:
    qp = q_e["plugins"].get(ptype, {"count": 0, "avg_ms": 0.0})
    sp = s_e["plugins"].get(ptype, {"count": 0, "avg_ms": 0.0})
    lines.append(f"| `{ptype}` | {qp['count']} | {qp['avg_ms']:.4f} ms | {sp['count']} | {sp['avg_ms']:.4f} ms |")
lines.append("")

if compare_snapshot_path and os.path.exists(compare_snapshot_path):
    with open(compare_snapshot_path, "r", encoding="utf-8") as cf:
        prev = json.load(cf)
    lines.append(f"## 3. Cumulative Delta Since Snapshot `{prev.get('timestamp_utc', 'previous')}`")
    lines.append("")
    lines.append("| Metric Delta | `qwen-demo` / `qwen-pool` | `smollm-demo` / `smollm-pool` |")
    lines.append("|---|---:|---:|")
    pq_m = prev["models"]["qwen-demo"]
    ps_m = prev["models"]["smollm-demo"]
    pq_e = prev["epp"]["qwen-pool-epp"]
    ps_e = prev["epp"]["smollm-pool-epp"]
    lines.append(f"| `+ inference_objective_request_total` (EPP) | +{int(q_e['objective_request_total'] - pq_e['objective_request_total'])} | +{int(s_e['objective_request_total'] - ps_e['objective_request_total'])} |")
    lines.append(f"| `+ llamacpp:prompt_tokens_total` | +{int(q_m['prompt_tokens_total'] - pq_m['prompt_tokens_total'])} | +{int(s_m['prompt_tokens_total'] - ps_m['prompt_tokens_total'])} |")
    lines.append(f"| `+ llamacpp:tokens_predicted_total` | +{int(q_m['tokens_predicted_total'] - pq_m['tokens_predicted_total'])} | +{int(s_m['tokens_predicted_total'] - ps_m['tokens_predicted_total'])} |")
    lines.append(f"| `+ llamacpp:prompt_seconds_total` | +{q_m['prompt_seconds_total'] - pq_m['prompt_seconds_total']:.3f}s | +{s_m['prompt_seconds_total'] - ps_m['prompt_seconds_total']:.3f}s |")
    lines.append(f"| `+ llamacpp:tokens_predicted_seconds_total` | +{q_m['tokens_predicted_seconds_total'] - pq_m['tokens_predicted_seconds_total']:.3f}s | +{s_m['tokens_predicted_seconds_total'] - ps_m['tokens_predicted_seconds_total']:.3f}s |")
    lines.append("")

lines.append("## Node & Pod Resource Snapshot (`kubectl top`)")
lines.append("")
lines.append("```text")
lines.append("# Nodes")
lines.append(node_top.strip())
lines.append("")
lines.append("# Pods")
lines.append(pod_top.strip())
lines.append("```")
lines.append("")

summary_md = "\n".join(lines)
summary_path = os.path.join(results_dir, "summary.md")
with open(summary_path, "w", encoding="utf-8") as f:
    f.write(summary_md)

if os.environ.get("METRICS_QUIET", "0") != "1":
    print(summary_md)
PY

log "=================================================================="
log "Metrics saved to: ${RESULTS_DIR}"
log "  - ${RESULTS_DIR}/qwen.metrics"
log "  - ${RESULTS_DIR}/smollm.metrics"
log "  - ${RESULTS_DIR}/qwen-epp.metrics"
log "  - ${RESULTS_DIR}/smollm-epp.metrics"
log "  - ${RESULTS_DIR}/summary.md"
log "=================================================================="
