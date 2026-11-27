#!/usr/bin/env bash
# Tears down the re:Invent 2026 local demo environment.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

echo "re:Invent 2026 — Demo Cleanup"
echo "───────────────────────"

# Confirm before tearing anything down (this also kills the UI port-forwards).
warn "This will DESTROY the kind cluster '${DEMO_NAME}' and stop all UI port-forwards."
read -r -p "Type 'yes' to continue: " _confirm || _confirm=""
if [[ "${_confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

# Stop the dashboard proxy + port-forwards started by ui.sh (harmless if none).
info "Stopping UI port-forwards and the dashboard proxy..."
# Kill only THIS instance's listeners (by port) so another running demo keeps its forwards.
for p in ${ARGOCD_PORT} ${GITEA_PORT} ${BACKSTAGE_PORT} ${DEX_PORT} ${CROSSVIEW_PORT} ${DASH_PORT} ${CTL_PORT}; do
  lsof -ti tcp:"$p" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
done

# Delete demo CRs first so Crossplane can clean up composed resources
info "Removing demo resources (Crossplane will cascade-delete composed resources)..."
kubectl config use-context ${KUBE_CONTEXT} 2>/dev/null || true

# The '|| true' guards matter: if the XRD was never installed (e.g. you ran
# start.sh but not setup_*.sh), this resource TYPE doesn't exist and kubectl
# exits nonzero — which under 'set -e' would abort before we delete the cluster.
# Delete every onboarded Service so Crossplane cascade-cleans the composed
# Argo CD apps + registrations before the cluster goes away.
kubectl delete services.lockhead.cloud --all -A --ignore-not-found 2>/dev/null || true

info "Waiting 15s for Crossplane to clean up composed resources..."
sleep 15

# Delete the kind cluster.
# idpbuilder bundles kind internally so we prefer idpbuilder delete,
# but fall back to stopping the Docker containers directly (no 'kind' CLI needed).
if command -v idpbuilder >/dev/null 2>&1; then
  info "Deleting kind cluster via idpbuilder..."
  demo_idpbuilder delete --name ${DEMO_NAME} 2>/dev/null || true
elif command -v kind >/dev/null 2>&1; then
  kind delete cluster --name ${DEMO_NAME} 2>/dev/null || true
else
  info "Removing kind node containers via Docker..."
  docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" --format "{{.Names}}" | \
    xargs -r docker rm -f 2>/dev/null || true
  # (the shared 'kind' docker network is left alone: other demo instances use it)
fi

demo_forget_kubeconfig
success "Demo environment removed."
