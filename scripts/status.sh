#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo " Cluster & GKE Inference Gateway Status"
echo "============================================================"

echo "--- Nodes ---"
kubectl get nodes -o wide

echo ""
echo "--- Node & Pod Resource Usage (kubectl top) ---"
kubectl top nodes || true
kubectl top pods || true

echo ""
echo "--- Pods ---"
kubectl get pods -o wide

echo ""
echo "--- Services (Internal ClusterIP) ---"
kubectl get services -o wide

echo ""
echo "--- Gateway & HTTPRoute ---"
kubectl get gateway,httproute -o wide

echo ""
echo "--- InferencePools & InferenceObjectives ---"
kubectl get inferencepool,inferenceobjective -o wide

echo ""
echo "--- GKE Gateway Policies & Extensions ---"
kubectl get gcproutingextension,gcpbackendpolicy,healthcheckpolicy -o wide

GW_IP="$(kubectl get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
echo ""
echo "============================================================"
echo " Public Inference Endpoint: http://${GW_IP:-<pending>}/v1/chat/completions"
echo "============================================================"
