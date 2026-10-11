#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo " End-to-End Verification — GKE Inference Gateway CPU MVP"
echo "============================================================"

GW_IP="$(kubectl get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
if [[ -z "${GW_IP}" ]]; then
  echo "ERROR: Gateway 'inference-gateway' has no external IP address." >&2
  exit 1
fi

ENDPOINT="http://${GW_IP}/v1/chat/completions"
echo "Target Public Endpoint: ${ENDPOINT}"
echo ""

echo "--- Step 0: Wait for Regional External ALB Data Plane & Backend Health Checks ---"
READY=0
for attempt in $(seq 1 45); do
  CODE_QWEN="$(curl -s -o /tmp/gw_warmup.json -w '%{http_code}' --max-time 15 \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen-demo","messages":[{"role":"user","content":"Hi"}],"max_tokens":4}' || echo "000")"
  CODE_SMOLLM="$(curl -s -o /tmp/gw_warmup_smollm.json -w '%{http_code}' --max-time 15 \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{"model":"smollm-demo","messages":[{"role":"user","content":"Hi"}],"max_tokens":4}' || echo "000")"
  CODE_UNKNOWN="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{"model":"nonexistent-model","messages":[{"role":"user","content":"Hi"}],"max_tokens":4}' || echo "000")"
  if [[ "${CODE_QWEN}" == "200" && "${CODE_SMOLLM}" == "200" && "${CODE_UNKNOWN}" == "404" ]]; then
    READY=1
    echo "[OK] Gateway data plane and all regional Envoy proxies converged (qwen=${CODE_QWEN}, smollm=${CODE_SMOLLM}, unknown=${CODE_UNKNOWN} on attempt ${attempt})."
    break
  fi
  echo "  [${attempt}/45] Waiting for load balancer convergence (qwen=${CODE_QWEN}, smollm=${CODE_SMOLLM}, unknown=${CODE_UNKNOWN})..."
  sleep 10
done

if [[ "${READY}" -ne 1 ]]; then
  echo "ERROR: Gateway data plane did not return HTTP 200 within timeout." >&2
  cat /tmp/gw_warmup.json >&2 || true
  exit 1
fi

echo ""
echo "============================================================"
echo " Test 1: Route to Model A (qwen-demo / Qwen2.5-0.5B-Instruct)"
echo "============================================================"
QWEN_RESP_FILE="/tmp/test1_qwen_response.json"
QWEN_STATUS="$(curl -s -o "${QWEN_RESP_FILE}" -w '%{http_code}' --max-time 60 \
  -X POST "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-demo",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user", "content": "State your model family in one short sentence and name two planets."}
    ],
    "max_tokens": 64,
    "temperature": 0.1
  }')"

echo "HTTP Status: ${QWEN_STATUS}"
jq . "${QWEN_RESP_FILE}"

if [[ "${QWEN_STATUS}" != "200" ]]; then
  echo "ERROR: Expected HTTP 200 for qwen-demo, got ${QWEN_STATUS}" >&2
  exit 1
fi

QWEN_MODEL_FIELD="$(jq -r '.model' "${QWEN_RESP_FILE}")"
QWEN_CONTENT="$(jq -r '.choices[0].message.content' "${QWEN_RESP_FILE}")"
if [[ "${QWEN_MODEL_FIELD}" != "qwen-demo" || -z "${QWEN_CONTENT}" || "${QWEN_CONTENT}" == "null" ]]; then
  echo "ERROR: Invalid response payload for qwen-demo" >&2
  exit 1
fi
echo "[PASS] Test 1 (qwen-demo) succeeded. Returned model='${QWEN_MODEL_FIELD}'."

echo ""
echo "============================================================"
echo " Test 2: Route to Model B (smollm-demo / SmolLM2-360M-Instruct)"
echo "============================================================"
SMOLLM_RESP_FILE="/tmp/test2_smollm_response.json"
SMOLLM_STATUS="$(curl -s -o "${SMOLLM_RESP_FILE}" -w '%{http_code}' --max-time 60 \
  -X POST "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "smollm-demo",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user", "content": "Write one short sentence explaining what Kubernetes is."}
    ],
    "max_tokens": 64,
    "temperature": 0.1
  }')"

echo "HTTP Status: ${SMOLLM_STATUS}"
jq . "${SMOLLM_RESP_FILE}"

if [[ "${SMOLLM_STATUS}" != "200" ]]; then
  echo "ERROR: Expected HTTP 200 for smollm-demo, got ${SMOLLM_STATUS}" >&2
  exit 1
fi

SMOLLM_MODEL_FIELD="$(jq -r '.model' "${SMOLLM_RESP_FILE}")"
SMOLLM_CONTENT="$(jq -r '.choices[0].message.content' "${SMOLLM_RESP_FILE}")"
if [[ "${SMOLLM_MODEL_FIELD}" != "smollm-demo" || -z "${SMOLLM_CONTENT}" || "${SMOLLM_CONTENT}" == "null" ]]; then
  echo "ERROR: Invalid response payload for smollm-demo" >&2
  exit 1
fi
echo "[PASS] Test 2 (smollm-demo) succeeded. Returned model='${SMOLLM_MODEL_FIELD}'."

echo ""
echo "============================================================"
echo " Test 3: Unknown Model Name (nonexistent-model)"
echo "============================================================"
UNKNOWN_RESP_FILE="/tmp/test3_unknown_response.txt"
UNKNOWN_STATUS="$(curl -s -o "${UNKNOWN_RESP_FILE}" -w '%{http_code}' --max-time 30 \
  -X POST "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nonexistent-model",
    "messages": [
      {"role": "user", "content": "Hello"}
    ],
    "max_tokens": 16
  }')"

echo "HTTP Status: ${UNKNOWN_STATUS}"
cat "${UNKNOWN_RESP_FILE}"
echo ""

if [[ "${UNKNOWN_STATUS}" != "404" ]]; then
  echo "ERROR: Expected HTTP 404 for unknown model 'nonexistent-model', got ${UNKNOWN_STATUS}" >&2
  exit 1
fi
echo "[PASS] Test 3 (nonexistent-model) returned HTTP 404 (unmatched HTTPRoute header) without routing to any model backend."

echo ""
echo "============================================================"
echo " Routing Evidence from BBR, EPP, and Model Server Logs"
echo "============================================================"
echo "--- Body-Based Router (BBR) recent logs ---"
kubectl logs deployment/body-based-router --tail=15 || true
echo ""
echo "--- qwen-pool-epp recent logs ---"
kubectl logs deployment/qwen-pool-epp --tail=15 || true
echo ""
echo "--- smollm-pool-epp recent logs ---"
kubectl logs deployment/smollm-pool-epp --tail=15 || true
echo ""
echo "--- qwen-demo (llama-server) recent logs ---"
kubectl logs deployment/qwen-demo -c llama-server --tail=10 || true
echo ""
echo "--- smollm-demo (llama-server) recent logs ---"
kubectl logs deployment/smollm-demo -c llama-server --tail=10 || true

echo ""
echo "============================================================"
echo " ALL E2E TESTS PASSED SUCCESSFULLY"
echo "============================================================"
