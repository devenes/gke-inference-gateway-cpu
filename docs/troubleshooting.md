# Troubleshooting Guide — GKE Inference Gateway CPU MVP

## 1. Quick Diagnostic Commands

Run the built-in status, metrics, streaming, and benchmark targets:

```bash
# Inspect nodes, pods, resource usage, InferencePools, and Gateway IP
make status

# Run fast local unit tests for the deterministic rule-based classifier
make test-classifier

# Run non-streaming E2E routing verification (qwen-demo, smollm-demo, 404 check)
make test

# Run live E2E verification for explicit + automatic model routing (9 cases)
make test-auto-routing

# Verify SSE streaming ("stream": true) and measure true TTFT (explicit + auto)
make test-streaming

# Scrape and summarize Prometheus metrics from both model pods and Endpoint Pickers
make metrics

# Run sequential and bounded concurrent end-to-end latency/throughput benchmarks
make benchmark

# Run status + metrics + test-streaming in sequence
make diagnostics
```

Or inspect individual layers manually:

```bash
# Check Gateway programming status and external IP
kubectl get gateway inference-gateway -o yaml

# Check HTTPRoute attachment and backend status (including fallback auto-model-router rule)
kubectl describe httproute llm-inference-route

# Check InferencePool status conditions
kubectl describe inferencepool qwen-pool smollm-pool

# Check GKE Gateway extension and policy reconciliation
kubectl describe gcproutingextension body-based-router
kubectl describe gcpbackendpolicy qwen-pool smollm-pool auto-model-router
kubectl describe healthcheckpolicy qwen-pool smollm-pool bbr-healthcheck auto-model-router

# Inspect structured JSON routing decisions from auto-model-router
kubectl logs deployment/auto-model-router --tail=50
```

---

## 2. Common Issues & Resolutions

### 2.1 `Gateway` Stuck in `Programmed: False` or Missing Proxy-Only Subnet

**Symptom:**
`kubectl describe gateway inference-gateway` reports an error mentioning `REGIONAL_MANAGED_PROXY` or failing to allocate regional Envoy proxies.

**Cause:**
`gke-l7-regional-external-managed` requires an active `REGIONAL_MANAGED_PROXY` subnet in the same VPC and region (`us-central1`).

**Resolution:**
Verify that Terraform provisioned `google_compute_subnetwork.proxy_only`:
```bash
gcloud compute networks subnets list --project="${PROJECT_ID}" --filter="purpose=REGIONAL_MANAGED_PROXY"
```

---

### 2.2 `HTTP 502` / `HTTP 503` Immediately After `Gateway` Becomes `Programmed: True`

**Symptom:**
`kubectl get gateway inference-gateway` shows `PROGRAMMED=True` and an external IP, but `curl` returns `502 Bad Gateway` or `503 Service Unavailable` for the first 60–120 seconds.

**Cause:**
After the GKE Gateway controller creates the GCP Regional External Application Load Balancer forwarding rule, GCP health check probers (`130.211.0.0/22`, `35.191.0.0/16`) and regional Envoy proxies (`10.10.1.0/24`) take 1–2 minutes to mark the Network Endpoint Groups (NEGs) for `body-based-router`, `qwen-pool`, and `smollm-pool` healthy.

**Resolution:**
1. Wait 60–120 seconds (`scripts/test-e2e.sh` automatically polls until the data plane is warm).
2. Confirm the VPC firewall rule `<cluster>-allow-proxy-and-hc` allows TCP ports `8080, 9002, 9003, 9004, 9005` from `10.10.1.0/24`, `130.211.0.0/22`, and `35.191.0.0/16`.

---

### 2.3 `HTTP 404 Not Found` on Valid Model Requests

**Symptom:**
Sending `POST /v1/chat/completions` with `"model": "qwen-demo"` returns `HTTP 404`.

**Cause:**
Either:
1. The request was missing `-H "Content-Type: application/json"`, or
2. `body-based-router` (`GCPRoutingExtension`) is not healthy or not attached to `Gateway/inference-gateway`, so `X-Gateway-Model-Name` was not injected into the request headers before `HTTPRoute` evaluation.

**Resolution:**
1. Always include `-H "Content-Type: application/json"`.
2. Check BBR logs and health:
   ```bash
   kubectl logs deployment/body-based-router --tail=50
   kubectl describe gcproutingextension body-based-router
   ```

---

### 2.4 EPP Pod Pending (`Insufficient cpu` or `Insufficient memory`)

**Symptom:**
`qwen-pool-epp` or `smollm-pool-epp` remains in `Pending` state with `0/1 nodes are available: Insufficient cpu, Insufficient memory`.

**Cause:**
The upstream `oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool` (`v1.5.0`) chart defaults to `requests: { cpu: "4", memory: 8Gi }`. If installed without `-f k8s/inference/qwen-pool-values.yaml`, it cannot schedule on an `e2-standard-2` node.

**Resolution:**
Always pass `-f k8s/inference/qwen-pool-values.yaml` and `-f k8s/inference/smollm-pool-values.yaml` (which override EPP requests to `50m CPU / 128Mi memory`), or run `make deploy`.

---

### 2.5 `terraform destroy` Fails with `resourceInUseByAnotherResource` on VPC or Subnets

**Symptom:**
Running `terraform destroy` directly while the Kubernetes `Gateway` still exists fails to delete the proxy-only subnet or VPC network.

**Cause:**
The GKE Gateway controller dynamically provisions GCP load-balancer resources (`ForwardingRule`, `TargetHttpProxy`, `UrlMap`, `BackendService`, `NetworkEndpointGroup`) inside the VPC when `Gateway/inference-gateway` exists.

**Resolution:**
Always use `make destroy`, or delete the Kubernetes Gateway first and wait ~90 seconds before running `terraform destroy`:
```bash
kubectl delete -f k8s/gateway/ --ignore-not-found=true
sleep 90
terraform -chdir=terraform destroy
```

---

### 2.6 Endpoint Picker `:9090/metrics` Returns `HTTP 401 Unauthorized`

**Symptom:**
Scraping `svc/qwen-pool-epp:9090/metrics` or `svc/smollm-pool-epp:9090/metrics` via `kubectl port-forward` returns `HTTP 401 Unauthorized` (`Authentication failed`).

**Cause:**
The `inferencepool:v1.5.0` Helm chart defaults `inferenceExtension.monitoring.prometheus.auth.enabled` to `true`, which passes `--metrics-endpoint-auth=true` to the EPP container and requires a Kubernetes `ServiceAccount` bearer token with RBAC permission on `/metrics`.

**Resolution:**
Ensure `inferenceExtension.monitoring.prometheus.auth.enabled: false` is set in both `k8s/inference/qwen-pool-values.yaml` and `k8s/inference/smollm-pool-values.yaml` (the EPP Services remain internal-only `ClusterIP` resources), and apply via `make deploy` or `helm upgrade`.

---

### 2.7 Confusing Non-Streaming `curl` `time_starttransfer` with True TTFT

**Symptom:**
In non-streaming requests (`"stream": false`), `curl -w "%{time_starttransfer}"` reports ~3.1s–3.7s, nearly identical to `%{time_total}`, whereas streaming requests (`"stream": true`) begin emitting tokens in ~0.35s–0.42s.

**Cause:**
For non-streaming requests, `llama-server` finishes generating all completion tokens before writing the HTTP response body. Additionally, in SSE streaming mode (`"stream": true`), the very first SSE `data:` event emitted by `llama-server` contains `delta: {"role": "assistant", "content": null}` before the first token is decoded.

**Resolution:**
- Use `make test-streaming` (`scripts/test-streaming.sh`) to measure **True TTFT** (observed at **~0.42s** for `qwen-demo` and **~0.35s** for `smollm-demo`), which specifically timestamps the arrival of the first non-empty `choices[0].delta.content` chunk.
- Treat `http_ttfb_sec` in `make benchmark` (`scripts/benchmark.sh`) strictly as non-streaming HTTP first-byte latency.

---

### 2.8 Higher Per-Request Latency Under Concurrent Load on a Single `e2-standard-2` Node

**Symptom:**
During `make benchmark`, concurrent requests (`concurrency=2`) exhibit ~1.5x–1.8x higher per-request latency (`p50 ~6.66s` for `qwen-demo`, `~5.03s` for `smollm-demo`) compared to sequential requests (`p50 ~3.71s` and `~3.12s`), even though aggregate `End-to-End Tok/s` increases (`15.15 -> 17.38 tok/s` for Qwen; `17.66 -> 23.43 tok/s` for SmolLM).

**Cause:**
All six workloads (`qwen-demo`, `smollm-demo`, `qwen-pool-epp`, `smollm-pool-epp`, `body-based-router`, and `auto-model-router`) share a single 2-vCPU `e2-standard-2` node, and each `llama-server` pod runs with `--parallel 2` (`2` active KV slots) and `--threads 2`. When two requests hit the same model simultaneously, both KV slots decode in parallel (`llamacpp:n_busy_slots_per_decode > 1.0`) and split the 2 vCPUs.

**Resolution:**
This is expected behavior on a single 2-vCPU CPU node. Avoid setting `BENCH_CONCURRENCY > 4` on an `e2-standard-2` node (`scripts/benchmark.sh` enforces a safety cap of `BENCH_CONCURRENCY <= 4` and `BENCH_MAX_TOKENS <= 128`).

---

### 2.9 Inspecting Automatic Model Selection Decisions & EPP Counter Behavior

**Symptom:**
1. You want to verify why an omitted-`model` request chose `qwen-demo` or `smollm-demo`.
2. You notice that `inference_objective_request_total` on `qwen-pool-epp` / `smollm-pool-epp` only increments on explicit-model requests, whereas `llamacpp:tokens_predicted_total` increments on both explicit and automatic requests.

**Cause & Resolution:**
1. **Inspecting routing decisions**: Every request handled by `auto-model-router` returns HTTP response headers and emits a single-line JSON log entry:
   - Check response headers with `curl -i`:
     - `X-Auto-Selected-Model: qwen-demo` (or `smollm-demo`)
     - `X-Auto-Route-Reason: code-request` (or `reasoning-request`, `architecture-request`, `math-request`, `long-input`, `large-output`, `default-simple`)
     - `X-Auto-Route-Mode: auto`
   - Or tail the router logs:
     ```bash
     kubectl logs deployment/auto-model-router --tail=20
     ```
2. **Explicit vs. Automatic backend path**:
   - **Mode A (Explicit `"model": "qwen-demo"` or `"smollm-demo"`)** matches Rule 1 or Rule 2 on `HTTPRoute/llm-inference-route` (`X-Gateway-Model-Name` header match) and routes through `InferencePool` + `Endpoint Picker (EPP)` (`qwen-pool-epp` / `smollm-pool-epp`).
   - **Mode B (Missing / null / empty / whitespace `"model"`)** falls through to Rule 3 on `HTTPRoute/llm-inference-route` (`Service/auto-model-router:8080`), which classifies the prompt and forwards directly to the internal `ClusterIP` model `Service` (`qwen-demo:8080` or `smollm-demo:8080`) to avoid recursive Gateway hair-pinning. Consequently, `llama-server` metrics (`llamacpp:*`) record both Mode A and Mode B traffic, while EPP metrics (`inference_*`) record Mode A traffic routed via the `InferencePool`.
