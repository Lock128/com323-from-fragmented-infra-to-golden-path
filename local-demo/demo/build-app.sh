#!/usr/bin/env bash
# build-app.sh — build a service's REAL image and flip its deploy to it (GitOps).
#
# The golden path deploys an offline-friendly nginx page by default. This script
# is the "and here's the actual app, built and running" beat: it builds the
# per-language image FROM the service's own scaffolded Dockerfile, pushes it to
# the in-cluster Gitea OCI registry, and commits chart/values.yaml (app.enabled=
# true + the pushed image ref) back to the service repo — so Argo CD re-syncs and
# the Deployment runs the real Go / TypeScript / Python / PHP container.
#
# This stands in for a Gitea Actions runner building on push (Phase 2). We build
# from the host — the same proven path packages/4-observability/function/build.sh
# uses to push the Go function image — because a live in-cluster runner + DinD is
# slow and fragile on stage. The RESULT is identical: the real image, pulled by
# the node from the Gitea registry, running behind the service's ingress.
#
# Usage:  ./demo/build-app.sh <service-name> [tag]
#   e.g.  ./demo/build-app.sh checkout            # tag defaults to a short timestamp
#         ./demo/build-app.sh checkout v2
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

NAME="${1:?usage: build-app.sh <service-name> [tag]}"
TAG="${2:-$(date +%Y%m%d%H%M%S)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

command -v docker >/dev/null 2>&1 || die "docker is required to build the image."
# shellcheck source=lib-registry.sh
source "${SCRIPT_DIR}/lib-registry.sh"
kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

GITEA_USER="giteaAdmin"
GITEA_ORG="lockhead"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
INGRESS_HOST="gitea.cnoe.localtest.me"
PUSH_HOST="${INGRESS_HOST}:${IDP_PORT}"
# The image ref the chart will reference IN-CLUSTER (implicit :443 → ingress-nginx
# → Gitea). The node pulls it via the containerd certs.d mirror (fix_registry_pull.sh).
IMG_REPO="${INGRESS_HOST}/${GITEA_ORG}/${NAME}"
IMG_INCLUSTER="${IMG_REPO}:${TAG}"
IMG_PUSH="${PUSH_HOST}/${GITEA_ORG}/${NAME}:${TAG}"
BUILD_PLATFORM=()
if registry_is_ecr; then
  # EKS: push to private ECR. The nodes pull with their node role; no pull secret.
  # Build for the nodes' architecture, not the laptop's (an Apple Silicon Mac builds arm64).
  ecr_init || die "Could not set up ECR."
  IMG_REPO="${ECR_HOST}/${GITEA_ORG}/${NAME}"
  IMG_INCLUSTER="${IMG_REPO}:${TAG}"
  IMG_PUSH="${IMG_INCLUSTER}"
  BUILD_PLATFORM=(--platform "${DEMO_IMAGE_PLATFORM:-linux/amd64}")
fi

echo -e "${BOLD}Build + deploy the REAL image for '${NAME}' (tag ${TAG})${RESET}"
echo "──────────────────────────────────────────────────"

GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
[[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./ui.sh)"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

# ── ensure the registry-pull wiring is in place (idempotent) ─────────────────
# CoreDNS + CA + pull secret + the containerd certs.d mirror so the NODE can pull
# gitea.cnoe.localtest.me/... over the HTTPS ingress. Safe + fast to re-run.
if ! registry_is_ecr && [[ -x "${ROOT_DIR}/fix_registry_pull.sh" ]]; then
  info "Ensuring the in-cluster registry-pull wiring (containerd mirror, CA)..."
  bash "${ROOT_DIR}/fix_registry_pull.sh" >/dev/null 2>&1 || warn "fix_registry_pull.sh reported an issue — pull may fail."
fi

# ── reachability: gitea on :${GITEA_PORT} (git) and the registry on :${IDP_PORT} (push) ──────
_pf3100=""; _pf8543=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 & _pf3100=$!
fi
if ! registry_is_ecr && ! curl -sk -o /dev/null --max-time 3 "https://${PUSH_HOST}/v2/" 2>/dev/null; then
  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${IDP_PORT}:${IDP_PORT} >/dev/null 2>&1 & _pf8543=$!
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/build-${NAME}.XXXXXX")
cleanup() {
  [[ -n "${_pf3100}" ]] && kill "${_pf3100}" >/dev/null 2>&1 || true
  [[ -n "${_pf8543}" ]] && kill "${_pf8543}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
sleep 3

# ── 1. clone the service repo (the scaffold the platform created) ────────────
hdr "1. Fetching the service repository"
git clone -q "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${NAME}.git" "${WORK}" \
  || die "Could not clone ${GITEA_ORG}/${NAME}. Onboard it first (./demo/onboard-service.sh ${NAME} <team>)."
[[ -f "${WORK}/Dockerfile" ]] || die "No Dockerfile in the repo — nothing to build."
success "Cloned ${GITEA_ORG}/${NAME}."

# ── 2. build the image from the repo's own Dockerfile ────────────────────────
hdr "2. Building the image from the scaffolded Dockerfile"
echo -e "${DIM}docker build ${BUILD_PLATFORM[*]:-} -t ${IMG_PUSH} ${WORK}${RESET}"
docker build ${BUILD_PLATFORM[@]+"${BUILD_PLATFORM[@]}"} -t "${IMG_PUSH}" "${WORK}" || die "docker build failed."
success "Built ${IMG_PUSH}"

# ── 3. push to the Gitea OCI registry (over the HTTPS ingress) ───────────────
if registry_is_ecr; then
  hdr "3. Pushing to Amazon ECR (${ECR_HOST})"
  ecr_ensure_repo "${GITEA_ORG}/${NAME}" || die "Could not create the ECR repository ${GITEA_ORG}/${NAME}."
  ecr_login || die "docker login to ECR failed."
else
  hdr "3. Pushing to the in-cluster Gitea registry"
  echo "${GITEA_PASS}" | docker login "${PUSH_HOST}" -u "${GITEA_USER}" --password-stdin >/dev/null 2>&1 \
    || warn "docker login to ${PUSH_HOST} failed — the push may 401."
fi
docker push "${IMG_PUSH}" || die "docker push failed. Check the registry + login."
success "Pushed ${IMG_PUSH}"

# ── 4. flip the deploy to the real image — the GITOPS way ────────────────────
# Commit chart/values.yaml (app.enabled=true + the image ref) back to the service
# repo. The Composition's Argo CD app syncs chart/ with selfHeal, so it rolls the
# Deployment over to the real image automatically. We reference the IN-CLUSTER host
# so the node pulls via the containerd mirror.
hdr "4. Flipping the deploy to the real image (GitOps commit)"
VALUES="${WORK}/chart/values.yaml"
[[ -f "${VALUES}" ]] || die "No chart/values.yaml in the repo."
python3 - "${VALUES}" "${IMG_REPO}" "${TAG}" <<'PY'
import sys, re
path, repo, tag = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
# Flip the app.* block: enabled true, repository, tag. The block is 2-space indented.
src = re.sub(r'(?m)^(app:\n(?:[ \t].*\n)*?  enabled:).*$', r'\1 true', src, count=1)
src = re.sub(r'(?m)^(  repository:).*$', f'\\1 "{repo}"', src, count=1)
src = re.sub(r'(?m)^(  tag:).*$',        f'\\1 "{tag}"',  src, count=1)
open(path, 'w').write(src)
print("  app.enabled: true")
print(f"  app.repository: {repo}")
print(f"  app.tag: {tag}")
PY

git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
git -C "${WORK}" add chart/values.yaml
if git -C "${WORK}" diff --cached --quiet; then
  info "chart/values.yaml already points at this image — nothing to commit."
else
  git -C "${WORK}" commit -q -m "Deploy real image: ${NAME}:${TAG} (build-app.sh)"
  git -C "${WORK}" push -q origin main || git -C "${WORK}" push -q origin HEAD:main
  success "Committed + pushed chart/values.yaml — Argo CD will roll out the real image."
fi

# Nudge the deploy app to sync immediately.
kubectl annotate application "${NAME}" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

echo ""
success "Done. The platform is now running the real ${NAME} image."
# Where the service runs: the claim's namespace (team-<team>), so the commands below are copy-paste ready.
NS_RUN="$(kubectl get service.lockhead.cloud -A --field-selector "metadata.name=${NAME}" -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
NS_RUN="${NS_RUN:-team-<team>}"
echo -e "${DIM}Watch the rollout:${RESET} kubectl rollout status deploy/${NAME} -n ${NS_RUN}"
echo -e "${DIM}Image (in-cluster):${RESET} ${IMG_INCLUSTER}"
if registry_is_ecr; then
  echo -e "${BOLD}Open it:${RESET} kubectl port-forward -n ${NS_RUN} svc/${NAME} ${APP_PORT}:80   then http://localhost:${APP_PORT}"
else
  echo -e "${BOLD}Open it:${RESET} https://${NAME}.cnoe.localtest.me:${IDP_PORT}"
fi
