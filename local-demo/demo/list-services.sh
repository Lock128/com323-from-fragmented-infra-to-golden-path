#!/usr/bin/env bash
# list-services.sh — the platform's single pane of glass: every onboarded service
# and the fan-out it produced (Argo app health + the three registrations).
# Handy opener/closer, or to confirm state between demo acts.
#
# Usage:  ./demo/list-services.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

CYAN='\033[0;36m'; GREEN='\033[0;32m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
hdr() { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}lockhead.cloud — onboarded services${RESET}"
echo "──────────────────────────────────────────────────"

hdr "Service declarations (the developer-facing API)"
echo -e "${DIM}kubectl get services.lockhead.cloud -A${RESET}"
kubectl get services.lockhead.cloud -A 2>/dev/null \
  || echo "  (none yet — onboard one with ./demo/onboard-service.sh or onboard-existing.sh)"

hdr "Argo CD Applications the platform provisioned (deploys)"
echo -e "${DIM}kubectl get applications -n argocd -l lockhead.cloud/managed-by=crossplane${RESET}"
kubectl get applications -n argocd -l lockhead.cloud/managed-by=crossplane \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  2>/dev/null || echo "  (none)"

hdr "Downstream registrations (one row per service per system)"
echo -e "${DIM}kubectl get cm -A -l lockhead.cloud/managed-by=crossplane${RESET}"
kubectl get cm -A -l lockhead.cloud/managed-by=crossplane \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SERVICE:.metadata.labels.lockhead\.cloud/service,TYPE:.metadata.labels.lockhead\.cloud/registration' \
  2>/dev/null || echo "  (none)"

echo ""
echo -e "${BOLD}Drill into one:${RESET}  ./demo/show-deploy.sh <name> <team>   ./demo/show-registrations.sh <name>"
