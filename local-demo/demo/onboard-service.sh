#!/usr/bin/env bash
# onboard-service.sh — the SCRIPTED golden path (offline fallback for the
# Backstage portal flow). Does exactly what the "Onboard a new service"
# template does on stage:
#   1. Render the golden-path skeleton (app + Dockerfile + Helm chart + CI)
#   2. Create a Git repo in Gitea and push the scaffold
#   3. Apply the Service claim → Crossplane provisions Argo CD app + registrations
#
# Usage:  ./demo/onboard-service.sh <service-name> <team> [language] [tier]
#   e.g.  ./demo/onboard-service.sh checkout storefront go standard
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

NAME="${1:-checkout}"
TEAM="${2:-storefront}"
LANGUAGE="${3:-go}"
TIER="${4:-standard}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKELETON="${ROOT_DIR}/packages/5-backstage/service-template/skeleton"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Onboarding service '${NAME}' (team=${TEAM}, language=${LANGUAGE}, tier=${TIER})${RESET}"
echo "──────────────────────────────────────────────────"

# ─── credentials + Gitea reachability ────────────────────────────────────────
GITEA_USER="giteaAdmin"
# Service repos live under the 'lockhead' ORG (not the giteaAdmin user) so the
# scripted path matches the Backstage portal path. The publish:gitea action
# (v0.1.12) can ONLY create repos under an org, so both paths must agree. The
# org is created by setup_gitops.sh / setup_direct.sh (ensure_gitea_org).
GITEA_ORG="lockhead"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

if ! curl -s -o /dev/null "${GITEA_LOCAL}/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null; then
  info "Starting Gitea port-forward on :${GITEA_PORT}..."
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  sleep 3
fi

# ─── 1. render the skeleton (substitute ${{ values.x }}) ─────────────────────
hdr "1. Scaffolding from the golden-path skeleton (${LANGUAGE})"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/onboard-${NAME}.XXXXXX")
# The skeleton is split like the Backstage template: base/ holds the shared files
# (chart, CI, catalog, claim, README); langs/<language>/ holds the per-language
# app + Dockerfile. Copy base first, then overlay the chosen language — so a
# 'node' pick scaffolds a TypeScript app, 'python' a Python app, etc.
LANG_DIR="${SKELETON}/langs/${LANGUAGE}"
if [[ ! -d "${LANG_DIR}" ]]; then
  warn "No skeleton for language '${LANGUAGE}' (have: $(ls -m "${SKELETON}/langs")). Falling back to 'go'."
  LANG_DIR="${SKELETON}/langs/go"
fi
cp -R "${SKELETON}/base/." "${WORK}/"
cp -R "${LANG_DIR}/." "${WORK}/"
demo_rewrite_ports_in_tree "${WORK}"   # skeleton keeps the original ports; use this instance's

# Backstage uses ${{ values.x }}; render the same fields with sed here.
# Match both "${{ values.x }}" and "${{ parameters.x }}" just in case.
render() {
  # shellcheck disable=SC2016
  find "${WORK}" -type f -print0 | xargs -0 sed -i '' \
    -e "s/\${{ *values\.name *}}/${NAME}/g" \
    -e "s/\${{ *values\.team *}}/${TEAM}/g" \
    -e "s/\${{ *values\.language *}}/${LANGUAGE}/g" \
    -e "s/\${{ *values\.tier *}}/${TIER}/g"
}
render
success "Rendered app, Dockerfile, Helm chart, CI workflow, catalog-info."

# ─── 2. create the Gitea repo + push the scaffold ────────────────────────────
hdr "2. Creating the Git repository and pushing the scaffold"
# Ensure the 'lockhead' org exists (idempotent — setup usually created it),
# then create the repo UNDER THE ORG so it matches the Backstage portal path.
curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/admin/users/${GITEA_USER}/orgs" \
  -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
  -d "{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}" 2>/dev/null || true
echo -e "${DIM}POST ${GITEA_LOCAL}/api/v1/orgs/${GITEA_ORG}/repos  name=${NAME}${RESET}"
curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/orgs/${GITEA_ORG}/repos" \
  -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
  -d "{\"name\":\"${NAME}\",\"description\":\"${NAME} — onboarded via the lockhead.cloud golden path\",\"auto_init\":false,\"default_branch\":\"main\"}" || true

# Push the whole scaffold — including service-claim.yaml — so the repo matches
# what the Backstage portal path produces ("here's what the platform applied").
git -C "${WORK}" init -b main >/dev/null 2>&1
git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
git -C "${WORK}" add . >/dev/null 2>&1
git -C "${WORK}" commit -m "Initial scaffold from lockhead.cloud golden path" >/dev/null 2>&1
git -C "${WORK}" remote add gitea \
  "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${NAME}.git"
git -C "${WORK}" push gitea main --force >/dev/null 2>&1
success "Repo created + scaffold pushed: ${GITEA_LOCAL}/${GITEA_ORG}/${NAME}"

rm -rf "${WORK}"

# ─── 3. onboard via GitOps — Argo CD applies the Service CR from the repo ─────
# The service-claim.yaml we just pushed IS the Service CR. Instead of applying it
# imperatively, create a per-service Argo CD Application that syncs ONLY that file
# from the repo (directory.include) — matching the Backstage portal path exactly.
# Argo CD applies the CR → Crossplane fans it out. GitOps, not kubectl apply.
hdr "3. Onboarding via GitOps (Argo CD applies the Service CR from Git)"
echo -e "${DIM}kubectl apply -f - (Argo CD Application svc-${NAME} → syncs service-claim.yaml)${RESET}"
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svc-${NAME}
  namespace: argocd
  labels:
    lockhead.cloud/service-claim: ${NAME}
    lockhead.cloud/managed-by: scripted-golden-path
spec:
  project: default
  source:
    repoURL: http://my-gitea-http.gitea.svc.cluster.local:3000/${GITEA_ORG}/${NAME}.git
    targetRevision: main
    path: .
    directory:
      include: service-claim.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: team-${TEAM}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML
kubectl annotate application "svc-${NAME}" -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
success "GitOps app 'svc-${NAME}' created — Argo CD is applying the Service CR from Git."

echo ""
success "Service '${NAME}' onboarded via GitOps. The platform is now:"
echo "   • applying the Service CR from Git (Argo CD app: svc-${NAME})"
echo "   • deploying it via Argo CD  (app: ${NAME})"
echo "   • registering it with security scanning, SRE on-call, and reporting"
echo ""
echo -e "${BOLD}Next:${RESET}  ./demo/show-repo.sh ${NAME}   ./demo/show-deploy.sh ${NAME} ${TEAM}   ./demo/show-registrations.sh ${NAME}"
