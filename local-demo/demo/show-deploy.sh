#!/usr/bin/env bash
# show-deploy.sh — the Argo CD Application the platform provisioned, and the
# running workload it deployed from the service's new repo.
# Usage:  ./demo/show-deploy.sh <service-name> <team>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"
TEAM="${2:-storefront}"
NS="team-${TEAM}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
hdr() { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Deployment of '${NAME}' (namespace ${NS})${RESET}"
echo "──────────────────────────────────────────────────"

hdr "The Service CR — one declaration, expanded by the platform"
echo -e "${DIM}kubectl get service.lockhead.cloud ${NAME} -n ${NS}${RESET}"
kubectl get service.lockhead.cloud "${NAME}" -n "${NS}" 2>/dev/null \
  || echo "  (Service ${NAME} not found in ${NS} — did onboarding run?)"

hdr "Argo CD Application the Composition created"
echo -e "${DIM}kubectl get application ${NAME} -n argocd${RESET}"
kubectl get application "${NAME}" -n argocd \
  -o custom-columns='NAME:.metadata.name,REPO:.spec.source.repoURL,PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  2>/dev/null || echo "  (Application not found yet — Crossplane may still be reconciling)"

hdr "Running workload (deployed by Argo CD from the new repo)"
echo -e "${DIM}kubectl get deploy,pods,svc -n ${NS} -l app=${NAME}${RESET}"
kubectl get deploy,pods,svc -n "${NS}" -l "app=${NAME}" 2>/dev/null \
  || echo "  (workload not up yet — give Argo CD a few seconds to sync)"

echo ""
echo -e "${BOLD}Watch it go green:${RESET}  kubectl get application ${NAME} -n argocd -w"
