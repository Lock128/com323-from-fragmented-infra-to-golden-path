#!/usr/bin/env bash
# apply.sh (cloud / EKS) — the scripted golden path for the EKS cluster.
#
# "Apply stuff for the cloud version": onboards a service the same way the local
# demo/onboard-service.sh does, but against the EKS cluster this CDK app
# deployed. It:
#   1. renders the golden-path skeleton (app + Dockerfile + Helm chart + CI)
#   2. creates a Git repo in the in-cluster Gitea and pushes the scaffold
#   3. applies the Service claim → Crossplane fans it out (Argo CD app +
#      security / SRE / reporting registrations)
#
# kubectl uses this cluster's own kubeconfig file (~/.kube/<cluster>, see
# kubeconfig.sh); it is created on the first run if missing.
#
# Usage:  ./scripts/apply.sh <service-name> <team> [language] [tier]
#   e.g.  ./scripts/apply.sh checkout storefront go standard
set -euo pipefail

NAME="${1:-checkout}"
TEAM="${2:-storefront}"
LANGUAGE="${3:-go}"
TIER="${4:-standard}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kubeconfig.sh
source "${HERE}/kubeconfig.sh"
eks_use_kubeconfig
# The golden-path skeleton lives in the local-demo package tree (single source
# of truth — the EKS app reuses it rather than copying).
SKELETON="$(cd "${HERE}/../../local-demo/packages/5-backstage/service-template/skeleton" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

echo -e "${BOLD}Onboarding '${NAME}' (team=${TEAM}, language=${LANGUAGE}, tier=${TIER}) on EKS${RESET}"
echo "──────────────────────────────────────────────────"

# ─── credentials + Gitea reachability (via port-forward) ─────────────────────
GITEA_USER="giteaAdmin"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)
GITEA_LOCAL="http://localhost:3100"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

if ! curl -s -o /dev/null "${GITEA_LOCAL}/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null; then
  info "Starting Gitea port-forward on :3100..."
  kubectl port-forward -n gitea svc/my-gitea-http 3100:3000 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
  sleep 4
fi

# ─── 1. render the skeleton (substitute ${{ values.x }}) ─────────────────────
hdr "1. Scaffolding from the golden-path skeleton"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/onboard-${NAME}.XXXXXX")
cp -R "${SKELETON}/." "${WORK}/"

# macOS vs GNU sed in-place differ; detect and use the right form.
sed_inplace() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
while IFS= read -r -d '' f; do
  sed_inplace \
    -e "s/\${{ *values\.name *}}/${NAME}/g" \
    -e "s/\${{ *values\.team *}}/${TEAM}/g" \
    -e "s/\${{ *values\.language *}}/${LANGUAGE}/g" \
    -e "s/\${{ *values\.tier *}}/${TIER}/g" \
    "$f"
done < <(find "${WORK}" -type f -print0)
success "Rendered app, Dockerfile, Helm chart, CI workflow, catalog-info."

# ─── 2. create the Gitea repo + push the scaffold ────────────────────────────
hdr "2. Creating the Git repository and pushing the scaffold"
curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/user/repos" \
  -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
  -d "{\"name\":\"${NAME}\",\"description\":\"${NAME} — onboarded via the lockhead.cloud golden path (EKS)\",\"auto_init\":false,\"default_branch\":\"main\"}" || true

git -C "${WORK}" init -b main >/dev/null 2>&1
git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
git -C "${WORK}" add . >/dev/null 2>&1
git -C "${WORK}" commit -m "Initial scaffold from lockhead.cloud golden path" >/dev/null 2>&1
git -C "${WORK}" remote add gitea \
  "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:3100/${GITEA_USER}/${NAME}.git"
git -C "${WORK}" push gitea main --force >/dev/null 2>&1
success "Repo created + scaffold pushed: ${GITEA_LOCAL}/${GITEA_USER}/${NAME}"

# ─── 3. apply the Service claim → Crossplane onboarding ──────────────────────
hdr "3. Applying the Service claim (triggers the platform)"
kubectl create namespace "team-${TEAM}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "${WORK}/service-claim.yaml"

rm -rf "${WORK}"

echo ""
success "Service '${NAME}' onboarded onto the EKS platform. The platform is now:"
echo "   • deploying it via Argo CD  (app: ${NAME})"
echo "   • registering it with security scanning, SRE on-call, and reporting"
echo ""
echo -e "${BOLD}Watch it land:${RESET}"
echo "   kubectl get service.lockhead.cloud ${NAME} -n team-${TEAM} -o wide"
echo "   kubectl get application ${NAME} -n argocd"
echo "   kubectl get cm -A -l lockhead.cloud/service=${NAME}"
echo ""
echo -e "${BOLD}Or watch the live dashboard:${RESET}  ./scripts/ui.sh"
