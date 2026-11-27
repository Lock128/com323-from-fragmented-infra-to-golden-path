#!/usr/bin/env bash
# refresh-argo.sh — hard-refresh every Argo CD Application.
#
# Clears the transient "argocd-repo-server ... i/o timeout" DNS blip that can
# make an app fail to generate manifests. A hard refresh forces Argo to re-dial
# the repo-server and re-read Git. Safe + idempotent; run it any time an app
# looks stuck Unknown/Degraded for no real reason.
#
# Usage:  ./demo/refresh-argo.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

CYAN='\033[0;36m'; GREEN='\033[0;32m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Hard-refreshing all Argo CD Applications${RESET}"
echo "──────────────────────────────────────────────────"

apps=$(kubectl get applications -n argocd -o name 2>/dev/null)
if [[ -z "${apps}" ]]; then
  info "No Argo CD Applications found."
  exit 0
fi

for app in ${apps}; do
  name="${app#*/}"
  kubectl annotate "${app}" -n argocd \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
    && echo -e "  ${DIM}refreshed${RESET} ${name}" \
    || echo -e "  ${DIM}skip${RESET} ${name}"
done

info "Waiting a few seconds for Argo to re-reconcile..."
sleep 6

echo ""
echo -e "${BOLD}Current state:${RESET}"
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>&1

echo ""
success "All applications hard-refreshed."
