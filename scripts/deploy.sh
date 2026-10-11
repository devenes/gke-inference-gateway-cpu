#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-your-gcp-project-id}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-gke-inference-gw-cpu}"
IGW_VERSION="${IGW_VERSION:-v1.5.0}"

echo "============================================================"
echo " Deploying GKE Inference Gateway CPU MVP Workloads"
echo "============================================================"

echo "[1/7] Configuring kubectl credentials for ${CLUSTER_NAME} (${ZONE})..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${ZONE}" \
  --project "${PROJECT_ID}"

echo "[2/7] Installing Gateway API Inference Extension CRDs (${IGW_VERSION})..."
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/${IGW_VERSION}/config/crd/bases/inference.networking.k8s.io_inferencepools.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/${IGW_VERSION}/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/${IGW_VERSION}/config/crd/bases/inference.networking.x-k8s.io_inferencemodelrewrites.yaml"

echo "[3/7] Deploying CPU language model workloads (qwen-demo & smollm-demo)..."
kubectl apply -f "${REPO_ROOT}/k8s/models/qwen-deployment.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/models/smollm-deployment.yaml"

echo "[4/7] Deploying GKE Inference Gateway resource..."
kubectl apply -f "${REPO_ROOT}/k8s/gateway/gateway.yaml"

echo "[5/7] Installing InferencePool + Endpoint Picker (EPP) Helm releases (${IGW_VERSION})..."
helm upgrade --install qwen-pool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version "${IGW_VERSION}" \
  -f "${REPO_ROOT}/k8s/inference/qwen-pool-values.yaml" \
  --wait --timeout 5m

helm upgrade --install smollm-pool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version "${IGW_VERSION}" \
  -f "${REPO_ROOT}/k8s/inference/smollm-pool-values.yaml" \
  --wait --timeout 5m

echo "[6/7] Installing Body-Based Router (BBR) Helm release (${IGW_VERSION}) and routing resources..."
helm upgrade --install body-based-router \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing \
  --version "${IGW_VERSION}" \
  -f "${REPO_ROOT}/k8s/inference/bbr-values.yaml" \
  --wait --timeout 5m

# Ensure conservative CPU/memory requests and limits on body-based-router
kubectl set resources deployment/body-based-router \
  --requests=cpu=50m,memory=128Mi \
  --limits=cpu=500m,memory=512Mi

kubectl apply -f "${REPO_ROOT}/k8s/inference/inference-objectives.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/inference/auto-model-router.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/gateway/httproute.yaml"

echo "[7/7] Waiting for all deployments and Gateway programming..."
kubectl rollout status deployment/qwen-demo --timeout=10m
kubectl rollout status deployment/smollm-demo --timeout=10m
kubectl rollout status deployment/qwen-pool-epp --timeout=5m
kubectl rollout status deployment/smollm-pool-epp --timeout=5m
kubectl rollout status deployment/body-based-router --timeout=5m
kubectl rollout status deployment/auto-model-router --timeout=5m

echo "Waiting for Gateway 'inference-gateway' to be Programmed and assigned an external IP..."
for i in $(seq 1 60); do
  GW_IP="$(kubectl get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  GW_PROGRAMMED="$(kubectl get gateway inference-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ -n "${GW_IP}" && "${GW_PROGRAMMED}" == "True" ]]; then
    echo "[OK] Gateway 'inference-gateway' is Programmed with public IP: ${GW_IP}"
    break
  fi
  echo "  [${i}/60] Gateway status: Programmed=${GW_PROGRAMMED:-Pending}, IP=${GW_IP:-Pending} (sleeping 10s)..."
  sleep 10
done

GW_IP="$(kubectl get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
if [[ -z "${GW_IP}" ]]; then
  echo "ERROR: Gateway did not receive an external IP within timeout." >&2
  kubectl describe gateway inference-gateway >&2
  exit 1
fi

echo "============================================================"
echo " Deployment Complete!"
echo " Public Inference Endpoint: http://${GW_IP}/v1/chat/completions"
echo "============================================================"
