#!/usr/bin/env bash
# add-observability.sh — EXTEND THE PLATFORM with a GO composition function.
#
# The capstone extension. FinOps used patch-and-transform; this uses a Crossplane
# composition function WRITTEN IN GO (packages/4-observability/function/) that
# reacts to the service TIER (alert intensity + routing) and LANGUAGE (runtime
# dashboards + exporter) and emits a typed ObservabilitySetup record per service.
#
# "The logic outgrew patches — so we wrote the composition in Go." No change to
# the developer-facing Service API.
#
# GITOPS: commits to the platform-api repo; Argo CD reconciles it (selfHeal-safe).
# The Go function image must already be built + pushed (run the PREP step once:
#   packages/4-observability/function/build.sh).
#
# Usage:
#   ./demo/add-observability.sh            # install the Go function + wire the step
#   ./demo/add-observability.sh --remove   # revert to the previous state
#   ./demo/add-observability.sh --consume  # show the ObservabilitySetup records
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_DIR="${ROOT_DIR}/packages/4-observability"
BASE_COMP="${ROOT_DIR}/packages/2-platform-api/compositions/service-onboarding.yaml"
OBS_CRD="${OBS_DIR}/observability-crd.yaml"
OBS_FUNC="${OBS_DIR}/observability-function.yaml"
OBS_STEP="${OBS_DIR}/observability-step.yaml"

GITEA_USER="giteaAdmin"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
# shellcheck source=lib-registry.sh
source "${SCRIPT_DIR}/lib-registry.sh"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

MODE="add"
case "${1:-}" in
  --remove)  MODE="remove" ;;
  --consume) MODE="consume" ;;
  "" )       MODE="add" ;;
  *)         die "Unknown arg: $1 (use --remove or --consume)" ;;
esac

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

if [[ "${MODE}" == "consume" ]]; then
  echo -e "${BOLD}ObservabilitySetup — what the Go function decided per service${RESET}"
  echo "──────────────────────────────────────────────────"
  if ! kubectl get crd observabilitysetups.platform.lockhead.cloud >/dev/null 2>&1; then
    die "Observability not installed yet. Run ./demo/add-observability.sh first."
  fi
  echo -e "${DIM}kubectl get observabilitysetups -A${RESET}"
  kubectl get observabilitysetups -A 2>/dev/null || echo "  (none yet)"
  echo
  hdr "Per-service detail (tier × language → alerts + dashboards + routing)"
  kubectl get observabilitysetups -A -o jsonpath='{range .items[*]}{"\n"}{.spec.service}{" ("}{.spec.tier}{"/"}{.spec.language}{"): "}{.spec.summary}{end}{"\n"}' 2>/dev/null
  echo ""
  echo -e "${BOLD}The point:${RESET} a Go function expressed rules (tier × language → lists of"
  echo "alerts & dashboards) that patch-and-transform can't express cleanly."
  exit 0
fi

# ── add / remove push to the platform-api repo ───────────────────────────────
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
[[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./ui.sh)"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  _pf_pid=$!
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/obs-gitops.XXXXXX")
trap '[[ -n "${_pf_pid}" ]] && kill "${_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT
sleep 2

git -C "${WORK}" init -b main >/dev/null 2>&1
git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
git -C "${WORK}" remote add gitea \
  "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_USER}/platform-api.git"
git -C "${WORK}" fetch gitea main >/dev/null 2>&1 \
  && git -C "${WORK}" reset --hard gitea/main >/dev/null 2>&1 \
  || die "Could not fetch the platform-api repo. Is setup_gitops.sh done?"

CRD_DST="${WORK}/packages/2-platform-api/xrds/observability-crd.yaml"
FUNC_DST="${WORK}/packages/2-platform-api/xrds/observability-function.yaml"
COMP_DST="${WORK}/packages/2-platform-api/compositions/service-onboarding.yaml"

kick_services() {
  info "Nudging all services to re-reconcile (so the Go step runs)..."
  kubectl get xservices.lockhead.cloud -o name 2>/dev/null | while read -r x; do
    kubectl annotate "${x}" "demo/reconcile=$(date +%s)" --overwrite >/dev/null 2>&1 || true
  done
}

push_repo() {
  git -C "${WORK}" add -A
  if git -C "${WORK}" diff --cached --quiet; then
    info "platform-api already in the target state — nothing to commit."
  else
    git -C "${WORK}" commit -m "$1" >/dev/null
    git -C "${WORK}" push gitea main >/dev/null 2>&1 || git -C "${WORK}" push gitea main --force >/dev/null 2>&1
    success "Committed + pushed to platform-api (Argo CD will reconcile)."
  fi
  kubectl annotate app platform-xrds -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  kubectl annotate app platform-compositions -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

# Rebuild the service-onboarding composition's pipeline: add/remove the
# observability step. Reads the CURRENT repo copy (preserving the FinOps block if
# present) and writes it back. Idempotent. No yq dependency.
rewrite_pipeline() {  # $1 = add|remove
  local src="${COMP_DST}"
  python3 - "${src}" "${OBS_STEP}" "$1" > "${COMP_DST}.tmp" <<'PY'
import sys, yaml
comp = yaml.safe_load(open(sys.argv[1]))
step = yaml.safe_load(open(sys.argv[2]))
mode = sys.argv[3]
pipeline = comp["spec"]["pipeline"]
pipeline = [s for s in pipeline if s.get("step") != step["step"]]   # idempotent
if mode == "add":
    pipeline.append(step)
comp["spec"]["pipeline"] = pipeline
print(yaml.safe_dump(comp, sort_keys=False, default_flow_style=False))
PY
  mv "${COMP_DST}.tmp" "${COMP_DST}"
}

if [[ "${MODE}" == "remove" ]]; then
  echo -e "${BOLD}Reverting the Observability (Go function) extension${RESET}"
  echo "──────────────────────────────────────────────────"
  rm -f "${CRD_DST}" "${FUNC_DST}"
  # Rewrite the repo composition in place, removing only the observability step
  # (preserves the FinOps block if present).
  rewrite_pipeline remove
  push_repo "Revert: remove Observability (Go function) extension"
  info "Deleting observability records + Function from the cluster..."
  kubectl delete observabilitysetups --all -A --ignore-not-found 2>/dev/null || true
  kubectl delete function function-observability --ignore-not-found 2>/dev/null || true
  kubectl delete crd observabilitysetups.platform.lockhead.cloud --ignore-not-found 2>/dev/null || true
  kick_services
  success "Observability extension reverted."
  exit 0
fi

# ── MODE=add ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}Extending the platform: + Observability (a GO composition function)${RESET}"
echo -e "${DIM}When the logic outgrows patch-and-transform, drop into Go.${RESET}"
echo "──────────────────────────────────────────────────"

[[ -f "${OBS_CRD}" && -f "${OBS_FUNC}" && -f "${OBS_STEP}" ]] || die "Missing observability files under packages/4-observability/."

# Preflight: the function package must be built and pushed to the registry.
if registry_is_ecr; then
  ecr_init || die "Could not set up ECR."
  PKG_TAG=$(sed -n 's#.*function-observability:\([^[:space:]]*\).*#\1#p' "${OBS_FUNC}" | head -1)
  PKG_REF="${ECR_HOST}/lockhead/function-observability:${PKG_TAG}"
  if ! aws ecr describe-images --repository-name lockhead/function-observability \
        --image-ids "imageTag=${PKG_TAG}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    warn "The function package ${PKG_REF} is not in ECR yet. Building and pushing it now (needs docker, go, the crossplane CLI)."
    bash "${OBS_DIR}/function/build.sh" || die "Building the function package failed."
  fi
  # Crossplane's package manager cannot use the node role, so give it a pull secret
  # with a fresh ECR token (valid 12 hours).
  info "Creating the ecr-registry-creds pull secret (crossplane-system)..."
  ecr_pull_secret ecr-registry-creds crossplane-system || die "Could not create the ECR pull secret."
elif ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/v2/" 2>/dev/null; then
  warn "Gitea OCI registry not reachable on :${GITEA_PORT} — if the Function can't pull, run the prep build:"
  warn "  packages/4-observability/function/build.sh"
fi
hdr "Move 1 — install the Go function + the ObservabilitySetup API"
cp "${OBS_CRD}"  "${CRD_DST}"
if registry_is_ecr; then
  # Same Function, but the package comes from ECR and is pulled with the ECR secret.
  sed -e "s#^\( *package: \).*#\1${PKG_REF}#" -e "s#gitea-registry-creds#ecr-registry-creds#" "${OBS_FUNC}" > "${FUNC_DST}"
else
  cp "${OBS_FUNC}" "${FUNC_DST}"
fi
echo -e "  ${DIM}+ xrds/observability-crd.yaml       (ObservabilitySetup CRD)${RESET}"
echo -e "  ${DIM}+ xrds/observability-function.yaml  (Function → the Go image)${RESET}"

hdr "Move 2 — add a GO pipeline step to the service-onboarding Composition"
rewrite_pipeline add
echo -e "  ${DIM}~ service-onboarding Composition → + step 'observability' (functionRef: function-observability)${RESET}"

push_repo "Extend platform: Observability via a Go composition function"

info "Waiting for the Function to become Healthy (image pull may take a minute)..."
kubectl wait function/function-observability --for=condition=Healthy --timeout=180s 2>/dev/null \
  || warn "Function not Healthy yet — if it's stuck Pulling, the registry/TLS may need attention (see Troubleshooting in local-demo/README.md)."

kick_services

hdr "Watch the Go function compose per service (tier × language)"
info "Waiting for ObservabilitySetup records to appear..."
for _ in $(seq 1 30); do
  n=$(kubectl get observabilitysetups -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n}" -gt 0 ]] && break
  sleep 2
done
echo -e "${DIM}kubectl get observabilitysetups -A${RESET}"
kubectl get observabilitysetups -A 2>/dev/null || echo "  (none yet — give the Function a few more seconds)"

echo ""
success "Platform extended with a GO composition function. Alerts + dashboards derive from tier × language."
echo -e "${BOLD}See the detail:${RESET}  ./demo/add-observability.sh --consume"
echo -e "${BOLD}Revert:${RESET}        ./demo/add-observability.sh --remove"
