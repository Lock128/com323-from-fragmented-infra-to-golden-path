#!/usr/bin/env bash
# reset.sh (cloud / EKS) — removes an onboarded service so you can re-run the
# golden path. Deletes the Service claim (Crossplane cascade-deletes the Argo CD
# app + registrations) and the Gitea repo. Does NOT touch the cluster itself.
#
# Usage:  ./scripts/reset.sh <service-name> <team>
set -euo pipefail

NAME="${1:-checkout}"
TEAM="${2:-storefront}"
# kubectl uses this cluster's own kubeconfig file (~/.kube/<cluster>).
# shellcheck source=kubeconfig.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubeconfig.sh"
eks_use_kubeconfig

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }

info "Deleting Service claim ${NAME} in team-${TEAM} (Crossplane cascades)..."
kubectl delete service.lockhead.cloud "${NAME}" -n "team-${TEAM}" --ignore-not-found

info "Deleting Gitea repo ${NAME}..."
GITEA_USER="giteaAdmin"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)
if ! curl -s -o /dev/null "http://localhost:3100/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http 3100:3000 >/dev/null 2>&1 &
  PF_PID=$!; trap 'kill ${PF_PID} 2>/dev/null || true' EXIT; sleep 4
fi
curl -s -o /dev/null -X DELETE \
  "http://localhost:3100/api/v1/repos/${GITEA_USER}/${NAME}" \
  -u "${GITEA_USER}:${GITEA_PASS}" || true

success "Service '${NAME}' reset — run ./scripts/apply.sh ${NAME} ${TEAM} to onboard again."
