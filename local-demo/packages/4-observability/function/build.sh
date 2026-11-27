#!/usr/bin/env bash
# build.sh — build the Go composition function into a Crossplane package (xpkg)
# and push it where the cluster can pull it. RUN THIS ONCE DURING PREP, not live.
#
# Why prep-only: building a Go function image + xpkg and pushing to a registry is
# the slow/fragile part (Go toolchain, docker build, registry TLS behind a proxy).
# The LIVE demo (./demo/add-observability.sh) only INSTALLS the already-pushed
# package — fast and offline-friendly, exactly like the FinOps YAML install.
#
# Prerequisites (checked below): docker, go, and the crossplane CLI (auto-installed
# if missing). The package is pushed to the in-cluster Gitea OCI registry so
# Crossplane's package manager can pull it at my-gitea-http.gitea.svc.cluster.local.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../instance.env"  # per-instance name + ports

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# Registry target: Gitea's OCI registry, reached over the idpbuilder HTTPS
# INGRESS. We push + pull via the SAME host (gitea.cnoe.localtest.me) so the
# pushed ref matches spec.package — Crossplane v2.4.0 can't pull plain HTTP, so
# the in-cluster HTTP host (my-gitea-http:3000) is NOT usable here. See
# fix_registry_pull.sh for the CoreDNS/CA/containerd wiring that makes the
# in-cluster pull work.
GITEA_ORG="lockhead"
IMG_NAME="function-observability"
IMG_TAG="${IMG_TAG:-v0.1.0}"
INGRESS_HOST="gitea.cnoe.localtest.me"
# Push goes to the ingress host on the nginx HTTPS port that Gitea's token
# redirect uses (:${IDP_PORT}). A local port-forward (set up below) makes it reachable.
PUSH_HOST="${INGRESS_HOST}:${IDP_PORT}"
RUNTIME_IMAGE="${PUSH_HOST}/${GITEA_ORG}/${IMG_NAME}-runtime:${IMG_TAG}"
XPKG_LOCAL="${HERE}/${IMG_NAME}.xpkg"
# The reference the Function resource uses (implicit :443 → ingress-nginx → Gitea).
PKG_REF_INCLUSTER="${INGRESS_HOST}/${GITEA_ORG}/${IMG_NAME}:${IMG_TAG}"
PKG_REF_PUSH="${PUSH_HOST}/${GITEA_ORG}/${IMG_NAME}:${IMG_TAG}"

# shellcheck source=../../../demo/lib-registry.sh
source "${HERE}/../../../demo/lib-registry.sh"
BUILD_PLATFORM=()
if registry_is_ecr; then
  # EKS: push the package to private ECR instead of the kind cluster's Gitea registry.
  # The tag comes from observability-function.yaml (what add-observability.sh installs);
  # build for the nodes' architecture (linux/amd64 unless DEMO_IMAGE_PLATFORM says otherwise).
  ecr_init || die "Could not set up ECR."
  IMG_TAG="${IMG_TAG:-$(sed -n 's#.*function-observability:\([^[:space:]]*\).*#\1#p' "${HERE}/../observability-function.yaml" | head -1)}"
  IMG_TAG="${IMG_TAG:-v0.1.0}"
  RUNTIME_IMAGE="${ECR_HOST}/${GITEA_ORG}/${IMG_NAME}-runtime:${IMG_TAG}"
  PKG_REF_INCLUSTER="${ECR_HOST}/${GITEA_ORG}/${IMG_NAME}:${IMG_TAG}"
  PKG_REF_PUSH="${PKG_REF_INCLUSTER}"
  BUILD_PLATFORM=(--platform "${DEMO_IMAGE_PLATFORM:-linux/amd64}")
fi
command -v docker >/dev/null 2>&1 || die "docker is required."
command -v go     >/dev/null 2>&1 || die "go is required to tidy the module."

# ── crossplane CLI (xpkg build/push) ─────────────────────────────────────────
if ! command -v crossplane >/dev/null 2>&1; then
  info "crossplane CLI not found — installing a local copy into ./bin ..."
  mkdir -p "${HERE}/bin"
  curl -fsSL "https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh" | \
    XP_CHANNEL=stable sh -s -- 2>/dev/null || true
  [[ -f "${HERE}/crossplane" ]] && mv "${HERE}/crossplane" "${HERE}/bin/crossplane"
  export PATH="${HERE}/bin:${PATH}"
fi
command -v crossplane >/dev/null 2>&1 || die "Could not install the crossplane CLI. Install it: https://docs.crossplane.io/latest/cli/"

# ── 1. tidy + vendor + build the runtime image ───────────────────────────────
info "go mod tidy + vendor (so the image build needs no network — proxy-safe)..."
go mod tidy
go mod vendor

info "Building the runtime image (${RUNTIME_IMAGE})..."
docker build ${BUILD_PLATFORM[@]+"${BUILD_PLATFORM[@]}"} -t "${RUNTIME_IMAGE}" "${HERE}"

# ── 2. build the xpkg (Function package) ─────────────────────────────────────
# The xpkg wraps the runtime image + package/crossplane.yaml metadata.
info "Building the Crossplane package (xpkg)..."
rm -f "${HERE}"/*.xpkg
crossplane xpkg build \
  --package-root="${HERE}/package" \
  --embed-runtime-image="${RUNTIME_IMAGE}" \
  --package-file="${XPKG_LOCAL}"
success "Built ${XPKG_LOCAL}"

# ── 3. push to the Gitea OCI registry (over the HTTPS ingress) ───────────────
# Gitea redirects the registry token request to its external HTTPS URL
# (gitea.cnoe.localtest.me:${IDP_PORT}). We push there directly so the token flow stays
# on one reachable host. A local port-forward maps :${IDP_PORT} → the ingress-nginx
# HTTPS target port. gitea.cnoe.localtest.me resolves to 127.0.0.1 on the host.
PF_PID=""
if registry_is_ecr; then
  info "Logging in to ECR ${ECR_HOST} (docker credential store; the crossplane CLI reuses it)..."
  ecr_ensure_repo "${GITEA_ORG}/${IMG_NAME}" || die "Could not create the ECR repository ${GITEA_ORG}/${IMG_NAME}."
  ecr_login || die "docker login to ECR failed."
  info "Pushing the package → ${PKG_REF_PUSH}"
  crossplane xpkg push --package-files="${XPKG_LOCAL}" "${PKG_REF_PUSH}" \
    || die "xpkg push failed. Check ECR access."
  success "Function package pushed to ECR."
  echo ""
  echo -e "${BOLD}Next (live):${RESET} ./demo/add-observability.sh   (DEMO_REGISTRY=ecr)"
  exit 0
fi
PF_PID=""
if ! curl -sk -o /dev/null --max-time 3 "https://${PUSH_HOST}/v2/" 2>/dev/null; then
  info "Starting a port-forward to the ingress-nginx HTTPS port (:${IDP_PORT})..."
  kubectl --context ${KUBE_CONTEXT} port-forward -n ingress-nginx \
    svc/ingress-nginx-controller ${IDP_PORT}:${IDP_PORT} >/dev/null 2>&1 &
  PF_PID=$!
  trap '[[ -n "${PF_PID}" ]] && kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT
  sleep 3
fi

GITEA_PASS=$(kubectl --context ${KUBE_CONTEXT} get secret -n gitea gitea-credential -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [[ -n "${GITEA_PASS}" ]]; then
  info "Logging in to the Gitea registry (docker login — the crossplane CLI reads docker creds)..."
  # The crossplane CLI has no `xpkg login`; it reuses the docker credential store.
  echo "${GITEA_PASS}" | docker login "${PUSH_HOST}" -u giteaAdmin --password-stdin 2>/dev/null \
    || warn "docker login failed — the push will likely 401."
fi

info "Pushing the package → ${PKG_REF_PUSH}"
# --insecure-skip-tls-verify: the ingress serves the self-signed idpbuilder cert.
crossplane xpkg push --insecure-skip-tls-verify \
  --package-files="${XPKG_LOCAL}" "${PKG_REF_PUSH}" \
  || die "xpkg push failed. Check the Gitea registry + docker login."

success "Function package pushed."

# ── 4. make the in-cluster PULL work (Crossplane + containerd) ───────────────
# Pushing isn't enough: the cluster must also be able to PULL over HTTPS. Apply
# the idempotent registry-pull fix now so ./demo/add-observability.sh just works.
if [[ -x "${HERE}/../../../fix_registry_pull.sh" ]]; then
  info "Applying the in-cluster registry-pull fix (CoreDNS + CA + pull secret + containerd)..."
  bash "${HERE}/../../../fix_registry_pull.sh" || warn "fix_registry_pull.sh reported an issue."
fi

echo ""
echo -e "${BOLD}observability-function.yaml → spec.package is already set to:${RESET}"
echo "  ${PKG_REF_INCLUSTER}"
echo ""
echo -e "${BOLD}Next (live):${RESET} ./demo/add-observability.sh"
