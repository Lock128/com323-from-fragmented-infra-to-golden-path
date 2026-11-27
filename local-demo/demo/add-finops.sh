#!/usr/bin/env bash
# add-finops.sh — EXTEND THE PLATFORM, LIVE (via GitOps).
#
# The "where this goes next" beat: add a brand-new downstream system — FinOps cost
# allocation — in two moves, with NO change to the developer-facing Service API:
#   1. Define a CRD            (FinOpsAllocation)
#   2. Add ONE resource block  to the service-onboarding Composition.
# Then every existing AND future Service gets a FinOpsAllocation, derived from the
# tier — which other teams/systems (chargeback, cost dashboards, a budgets
# controller) consume straight off the Kubernetes API.
#
# DONE THE GITOPS WAY: the platform API is installed by Argo CD from the
# platform-api repo (selfHeal on), so we can't just `kubectl apply` — Argo would
# revert it. Instead we COMMIT the change to Git and let Argo reconcile it. That
# is the honest story: extending the platform is a reviewed Git commit.
#
#   CRD         → packages/2-platform-api/xrds/finops-crd.yaml         (platform-xrds app)
#   Composition → packages/2-platform-api/compositions/service-onboarding.yaml  (platform-compositions app)
#
# Usage:
#   ./demo/add-finops.sh            # extend the platform (commit CRD + patched Composition)
#   ./demo/add-finops.sh --remove   # revert to the base platform (for rehearsals)
#   ./demo/add-finops.sh --consume  # show how another team/system consumes the CRD
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FINOPS_DIR="${ROOT_DIR}/packages/3-finops"
BASE_COMP="${ROOT_DIR}/packages/2-platform-api/compositions/service-onboarding.yaml"
FINOPS_RES="${FINOPS_DIR}/finops-resource.yaml"
FINOPS_CRD="${FINOPS_DIR}/finops-crd.yaml"            # XRD(s) → platform-xrds app
FINOPS_COMP="${FINOPS_DIR}/finops-composition.yaml"   # Composition → platform-compositions app

GITEA_USER="giteaAdmin"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

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

# ── consume: read-only, needs only the cluster ───────────────────────────────
if [[ "${MODE}" == "consume" ]]; then
  echo -e "${BOLD}How other teams & systems consume the FinOps CRD${RESET}"
  echo "──────────────────────────────────────────────────"
  if ! kubectl get crd finopsallocations.platform.lockhead.cloud >/dev/null 2>&1; then
    die "FinOps CRD not installed yet. Run ./demo/add-finops.sh first."
  fi
  hdr "A FinOps team's chargeback view — straight off the API, no exports"
  echo -e "${DIM}kubectl get finopsallocations -A${RESET}"
  kubectl get finopsallocations -A 2>/dev/null || echo "  (none yet — onboard a service)"

  hdr "Total committed monthly budget across all services"
  kubectl get finopsallocations -A -o jsonpath='{range .items[*]}{.spec.monthlyBudgetUSD}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {printf "  $%d / month across %d services\n", s, NR}'

  hdr "Per-cost-center rollup (what finance actually wants)"
  kubectl get finopsallocations -A \
    -o jsonpath='{range .items[*]}{.spec.costCenter}{" "}{.spec.monthlyBudgetUSD}{"\n"}{end}' 2>/dev/null \
    | awk '{cc[$1]+=$2} END {for (c in cc) printf "  %-16s $%d/mo\n", c, cc[c]}' | sort

  echo ""
  echo -e "${BOLD}The point:${RESET} nobody built a bespoke integration. FinOps, a cost"
  echo "dashboard, or a budgets controller all just list/watch the CRD — the"
  echo "platform published a typed contract and everyone else builds on it."
  exit 0
fi

# ── add / remove both push to the platform-api repo ──────────────────────────
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
[[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./start.sh / ./ui.sh)"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  _pf_pid=$!
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finops-gitops.XXXXXX")
trap '[[ -n "${_pf_pid}" ]] && kill "${_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT
sleep 2

# Clone the platform-api repo so we commit a fast-forward.
git -C "${WORK}" init -b main >/dev/null 2>&1
git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
git -C "${WORK}" remote add gitea \
  "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_USER}/platform-api.git"
git -C "${WORK}" fetch gitea main >/dev/null 2>&1 \
  && git -C "${WORK}" reset --hard gitea/main >/dev/null 2>&1 \
  || die "Could not fetch the platform-api repo. Is setup_gitops.sh done?"

CRD_DST="${WORK}/packages/2-platform-api/xrds/finops-crd.yaml"            # the FinOps XRD + record CRD
FINOPS_COMP_DST="${WORK}/packages/2-platform-api/compositions/finops-composition.yaml"  # the FinOps Composition
COMP_DST="${WORK}/packages/2-platform-api/compositions/service-onboarding.yaml"         # service comp (+finops block)

kick_services() {
  info "Nudging all services to re-reconcile against the new Composition..."
  kubectl get xservices.lockhead.cloud -o name 2>/dev/null | while read -r x; do
    kubectl annotate "${x}" "demo/reconcile=$(date +%s)" --overwrite >/dev/null 2>&1 || true
  done
}

push_repo() {
  local msg="$1"
  git -C "${WORK}" add -A
  if git -C "${WORK}" diff --cached --quiet; then
    info "platform-api already in the target state — nothing to commit."
  else
    git -C "${WORK}" commit -m "${msg}" >/dev/null
    git -C "${WORK}" push gitea main >/dev/null 2>&1 || git -C "${WORK}" push gitea main --force >/dev/null 2>&1
    success "Committed + pushed to platform-api (Argo CD will reconcile)."
  fi
  # Nudge the Argo apps to sync immediately.
  kubectl annotate app platform-xrds -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  kubectl annotate app platform-compositions -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

if [[ "${MODE}" == "remove" ]]; then
  echo -e "${BOLD}Reverting the platform to its base state (removing FinOps)${RESET}"
  echo "──────────────────────────────────────────────────"
  info "Removing the FinOps XRD + Composition + restoring the base service Composition in Git..."
  rm -f "${CRD_DST}" "${FINOPS_COMP_DST}"
  cp "${BASE_COMP}" "${COMP_DST}"   # the source tree's base composition (no finops)
  push_repo "Revert: remove FinOps extension (back to base platform)"
  info "Deleting FinOps claims, records, and APIs from the cluster..."
  kubectl delete finopsbudgets --all -A --ignore-not-found 2>/dev/null || true
  kubectl delete finopsallocations --all -A --ignore-not-found 2>/dev/null || true
  kubectl delete cm -A -l lockhead.cloud/registration=finops --ignore-not-found 2>/dev/null || true
  kubectl delete composition finops-budget --ignore-not-found 2>/dev/null || true
  kubectl delete xrd xfinopsbudgets.platform.lockhead.cloud --ignore-not-found 2>/dev/null || true
  kubectl delete crd finopsallocations.platform.lockhead.cloud --ignore-not-found 2>/dev/null || true
  kick_services
  success "Platform reverted to base. (Re-add with ./demo/add-finops.sh)"
  exit 0
fi

# ── MODE=add ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}Extending the platform: + FinOps cost allocation${RESET}"
echo -e "${DIM}Two moves, zero change to the developer-facing Service API — committed to Git.${RESET}"
echo "──────────────────────────────────────────────────"

[[ -f "${FINOPS_CRD}" && -f "${FINOPS_COMP}" && -f "${FINOPS_RES}" ]] || die "Missing FinOps files under packages/3-finops/."

hdr "Move 1 — define the FinOps API + its Composition"
cp "${FINOPS_CRD}" "${CRD_DST}"            # XRD (FinOpsBudget) + record CRD (FinOpsAllocation)
cp "${FINOPS_COMP}" "${FINOPS_COMP_DST}"   # Composition that DERIVES the budget from the tier
echo -e "  ${DIM}+ xrds/finops-crd.yaml  (FinOpsBudget XRD + FinOpsAllocation CRD)${RESET}"
echo -e "  ${DIM}+ compositions/finops-composition.yaml  (tier → allowed budget)${RESET}"

hdr "Move 2 — have service-onboarding create a FinOpsBudget per service"
# Append the FinOps resource to the Composition's resource list (single source of
# truth = the base composition in the source tree; FinOps is an additive snippet).
python3 - "${BASE_COMP}" "${FINOPS_RES}" > "${COMP_DST}" <<'PY'
import sys, yaml
comp = yaml.safe_load(open(sys.argv[1]))
res  = yaml.safe_load(open(sys.argv[2]))
resources = comp["spec"]["pipeline"][0]["input"]["resources"]
resources = [r for r in resources if r.get("name") != res["name"]]   # idempotent
resources.append(res)
comp["spec"]["pipeline"][0]["input"]["resources"] = resources
print(yaml.safe_dump(comp, sort_keys=False, default_flow_style=False))
PY
echo -e "  ${DIM}~ service-onboarding Composition → now 5 resources${RESET}"

push_repo "Extend platform: FinOpsBudget XRD + Composition + service fan-out"

info "Waiting for the FinOpsBudget API to be Established (Argo sync)..."
for _ in $(seq 1 30); do
  kubectl get xrd xfinopsbudgets.platform.lockhead.cloud >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=condition=Established xrd/xfinopsbudgets.platform.lockhead.cloud --timeout=30s >/dev/null 2>&1 || true

kick_services

hdr "Watch every service pick it up — the budget is DERIVED from the tier"
info "Waiting for FinOpsBudget claims + derived budgets to appear..."
for _ in $(seq 1 40); do
  n=$(kubectl get finopsallocations -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n}" -gt 0 ]] && break
  sleep 2
done
echo -e "${DIM}kubectl get finopsbudgets -A   (the claim — tier in, budget derived)${RESET}"
kubectl get finopsbudgets -A 2>/dev/null || echo "  (none yet — give Argo a few more seconds)"
echo -e "${DIM}kubectl get finopsallocations -A   (the published record)${RESET}"
kubectl get finopsallocations -A 2>/dev/null || echo "  (none yet)"

echo ""
success "Platform extended via GitOps. A FinOps Composition now DERIVES each service's allowed budget from its tier."
echo -e "${BOLD}Show who consumes it:${RESET}  ./demo/add-finops.sh --consume"
echo -e "${BOLD}Revert for a rehearsal:${RESET} ./demo/add-finops.sh --remove"
