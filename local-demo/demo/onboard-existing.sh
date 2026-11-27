#!/usr/bin/env bash
# onboard-existing.sh — onboard an EXISTING service onto the platform by just
# declaring its Service CR. No scaffold, no new repo — the "second door".
#
# The portal golden path SCAFFOLDS a brand-new repo. Many teams already have a
# service + Helm chart; for them onboarding is simply applying one Service CR.
# The SAME Crossplane Composition fans it out into an Argo CD Application + the
# security / SRE / reporting registrations. Same API, same outcome.
#
# Usage:
#   ./demo/onboard-existing.sh                 # GitOps path (default): commit the
#                                              # Service CR as service-claim.yaml
#                                              # into the service's OWN repo; a
#                                              # per-service Argo app (svc-<name>)
#                                              # applies it — same model as the
#                                              # portal + onboard-service.sh.
#   ./demo/onboard-existing.sh --direct        # kubectl apply the CR directly
#   ./demo/onboard-existing.sh --cr path.yaml  # use a different Service CR file
#
# Env overrides: NAME, TEAM, REPO (the existing service's repo name under the org).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED:-\033[0;31m}✗ $*${RESET}" >&2; exit 1; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

MODE="gitops"
CR_FILE="${SCRIPT_DIR}/existing-service.yaml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --direct) MODE="direct"; shift ;;
    --cr)     CR_FILE="$2"; shift 2 ;;
    *)        warn "Unknown arg: $1"; shift ;;
  esac
done

NAME="${NAME:-legacy-orders}"
TEAM="${TEAM:-storefront}"
REPO="${REPO:-${NAME}}"
GITEA_USER="giteaAdmin"
GITEA_ORG="lockhead"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Onboard EXISTING service '${NAME}' (team=${TEAM}) — ${MODE} path${RESET}"
echo "──────────────────────────────────────────────────"

GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
[[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./start.sh / ./ui.sh)"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  _pf_pid=$!
  trap '[[ -n "${_pf_pid}" ]] && kill "${_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK:-/nonexistent}"' EXIT
  sleep 3
fi

# ─── 1. make sure the "existing" repo actually exists (seed it once) ─────────
# For the demo we stand in for a real team's pre-existing repo by seeding one
# from the golden-path skeleton (app + Dockerfile + chart + CI). Idempotent.
hdr "1. Ensuring the existing service repo '${GITEA_ORG}/${REPO}' is present"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${REPO}")
if [[ "${HTTP}" == "200" ]]; then
  success "Repo '${GITEA_ORG}/${REPO}' already exists — treating it as the team's existing service."
else
  info "Repo not found — seeding an example existing service (chart + app) so Argo CD has something real to deploy."
  curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/admin/users/${GITEA_USER}/orgs" \
    -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
    -d "{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}" 2>/dev/null || true
  curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/orgs/${GITEA_ORG}/repos" \
    -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${REPO}\",\"description\":\"Example EXISTING service onboarded via the Service CR\",\"auto_init\":false,\"default_branch\":\"main\"}" || true

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/existing-${REPO}.XXXXXX")
  cp -R "${ROOT_DIR}/packages/5-backstage/service-template/skeleton/." "${WORK}/"
  demo_rewrite_ports_in_tree "${WORK}"
  # Render the skeleton placeholders the same way the scripted path does.
  find "${WORK}" -type f -print0 | xargs -0 sed -i '' \
    -e "s/\${{ *values\.name *}}/${NAME}/g" \
    -e "s/\${{ *values\.team *}}/${TEAM}/g" \
    -e "s/\${{ *values\.language *}}/php/g" \
    -e "s/\${{ *values\.tier *}}/standard/g" 2>/dev/null || true
  # Drop the service-claim.yaml — an existing repo wouldn't carry the platform CR.
  rm -f "${WORK}/service-claim.yaml"
  git -C "${WORK}" init -b main >/dev/null 2>&1
  git -C "${WORK}" config user.email "demo@example.com"
  git -C "${WORK}" config user.name  "Demo"
  git -C "${WORK}" add . >/dev/null 2>&1
  git -C "${WORK}" commit -m "Existing service (pre-dates the platform)" >/dev/null 2>&1
  git -C "${WORK}" remote add gitea \
    "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${REPO}.git"
  git -C "${WORK}" push gitea main --force >/dev/null 2>&1
  success "Seeded example existing repo: ${GITEA_LOCAL}/${GITEA_ORG}/${REPO}"
fi

# ─── 2. ensure the team namespace exists ─────────────────────────────────────
kubectl create namespace "team-${TEAM}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ─── 3. onboard by declaring the Service CR ──────────────────────────────────
if [[ "${MODE}" == "direct" ]]; then
  hdr "2. Onboarding by applying the Service CR directly"
  echo -e "${DIM}kubectl apply -f ${CR_FILE}${RESET}"
  kubectl apply -f "${CR_FILE}"
  success "Service CR applied. The SAME Composition now provisions the Argo CD app + registrations."
else
  hdr "2. Onboarding via GitOps (commit the Service CR to the repo; Argo CD applies it)"
  # The SAME GitOps model as the portal + ./demo/onboard-service.sh: commit the
  # Service CR as service-claim.yaml into the service's OWN repo, then a
  # per-service Argo CD app (svc-<name>) syncs just that file. The existing repo
  # didn't carry a claim (it predates the platform) — so we add one. Consistent,
  # per-service, and selfHeal/prune-safe for reset.
  WORK2=$(mktemp -d "${TMPDIR:-/tmp}/gitops-${NAME}.XXXXXX")
  git -C "${WORK2}" init -b main >/dev/null 2>&1
  git -C "${WORK2}" config user.email "demo@example.com"
  git -C "${WORK2}" config user.name  "Demo"
  git -C "${WORK2}" remote add gitea \
    "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${REPO}.git"
  git -C "${WORK2}" fetch gitea main >/dev/null 2>&1 && git -C "${WORK2}" reset --hard gitea/main >/dev/null 2>&1
  cp "${CR_FILE}" "${WORK2}/service-claim.yaml"
  git -C "${WORK2}" add "service-claim.yaml"
  if git -C "${WORK2}" diff --cached --quiet; then
    info "service-claim.yaml already present in ${GITEA_ORG}/${REPO} — nothing to push."
  else
    git -C "${WORK2}" commit -m "Onboard '${NAME}' onto lockhead.cloud (add Service CR)" >/dev/null
    git -C "${WORK2}" push gitea main >/dev/null 2>&1 || git -C "${WORK2}" push gitea main --force >/dev/null 2>&1
    success "Committed service-claim.yaml to ${GITEA_ORG}/${REPO} (GitOps source of truth)."
  fi
  rm -rf "${WORK2}"

  # Per-service Argo CD app that syncs ONLY service-claim.yaml from the repo.
  info "Creating the per-service Argo CD app 'svc-${NAME}' ..."
  kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svc-${NAME}
  namespace: argocd
  labels:
    lockhead.cloud/service-claim: ${NAME}
    lockhead.cloud/managed-by: onboard-existing
spec:
  project: default
  source:
    repoURL: http://my-gitea-http.gitea.svc.cluster.local:3000/${GITEA_ORG}/${REPO}.git
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
  success "Argo CD app 'svc-${NAME}' created — applying the Service CR from Git."
fi

echo ""
success "Existing service '${NAME}' onboarded via the ${MODE} path."
echo -e "${BOLD}See it fan out:${RESET}"
echo "  ./demo/show-deploy.sh ${NAME} ${TEAM}"
echo "  ./demo/show-registrations.sh ${NAME}"
echo "  kubectl get service.lockhead.cloud ${NAME} -n team-${TEAM} -o wide"
