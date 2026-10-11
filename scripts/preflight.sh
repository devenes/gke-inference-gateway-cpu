#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-your-gcp-project-id}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

echo "============================================================"
echo " Preflight Check — GKE Inference Gateway CPU MVP"
echo "============================================================"

REQUIRED_TOOLS=(terraform kubectl helm gcloud jq curl)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: Required tool '${tool}' is not installed or not in PATH." >&2
    exit 1
  fi
  echo "[OK] Found ${tool}: $(command -v "${tool}")"
done

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  echo "ERROR: No active gcloud account found. Run 'gcloud auth login'." >&2
  exit 1
fi
echo "[OK] Active gcloud account: ${ACTIVE_ACCOUNT}"

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ERROR: Application Default Credentials (ADC) not configured. Run 'gcloud auth application-default login'." >&2
  exit 1
fi
echo "[OK] Application Default Credentials (ADC) verified"

PROJECT_NUM="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -z "${PROJECT_NUM}" ]]; then
  echo "ERROR: Unable to access project '${PROJECT_ID}'." >&2
  exit 1
fi
echo "[OK] GCP Project: ${PROJECT_ID} (projectNumber: ${PROJECT_NUM})"

BILLING_ENABLED="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "${BILLING_ENABLED}" != "True" && "${BILLING_ENABLED}" != "true" ]]; then
  echo "ERROR: Billing is not enabled on project '${PROJECT_ID}'." >&2
  exit 1
fi
echo "[OK] Billing enabled on '${PROJECT_ID}': ${BILLING_ENABLED}"
echo "[OK] Target region/zone: ${REGION} / ${ZONE}"
echo "============================================================"
echo " Preflight checks passed."
echo "============================================================"
