#!/usr/bin/env bash
# change-tier.sh — THE MONEY MOMENT (GitOps).
# Change ONE field (the tier) and watch the platform re-derive scan cadence,
# on-call paging, escalation, and SLO across every downstream system — with no
# ticket, no manual wiring. Clear BEFORE → AFTER.
#
# GITOPS NOTE: onboarded services are GitOps-managed — a per-service Argo app
# (svc-<name>) syncs service-claim.yaml from the service's repo with selfHeal on.
# So a direct `kubectl patch` of the tier gets REVERTED in ~3s. The money moment
# therefore edits the tier in GIT (service-claim.yaml) and lets Argo sync it.
# Use --direct to patch the live CR instead (only sticks if the svc-<name> app is
# absent, e.g. onboarded with --direct, or for a quick offline poke).
#
# Usage:  ./demo/change-tier.sh <service-name> <team> [new-tier] [--direct]
#   e.g.  ./demo/change-tier.sh checkout storefront critical
#
# new-tier defaults to 'critical' (the most dramatic jump):
#   experimental | standard | critical
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"
TEAM="${2:-storefront}"
NEW_TIER="${3:-critical}"
NS="team-${TEAM}"
MODE="gitops"
for a in "$@"; do [[ "$a" == "--direct" ]] && MODE="direct"; done

GITEA_USER="giteaAdmin"
GITEA_ORG="lockhead"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

case "${NEW_TIER}" in
  experimental|standard|critical) ;;
  *) die "Invalid tier '${NEW_TIER}'. Use: experimental | standard | critical" ;;
esac

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

# Read the derived policy from the typed, platform-owned registration CRs.
snapshot() {
  local scan sre_window sre_slo sre_policy
  scan=$(kubectl get securityscan "scan-${NAME}" -n security-system -o jsonpath='{.spec.scanCadence}' 2>/dev/null || echo "?")
  sre_window=$(kubectl get oncallregistration "oncall-${NAME}" -n sre-system -o jsonpath='{.spec.pagingWindow}' 2>/dev/null || echo "?")
  sre_slo=$(kubectl get oncallregistration "oncall-${NAME}" -n sre-system -o jsonpath='{.spec.sloTarget}' 2>/dev/null || echo "?")
  sre_policy=$(kubectl get oncallregistration "oncall-${NAME}" -n sre-system -o jsonpath='{.spec.escalationPolicy}' 2>/dev/null || echo "?")
  printf "  scan cadence : %s\n  paging window: %s\n  escalation   : %s\n  SLO target   : %s\n" \
    "${scan}" "${sre_window:-?}" "${sre_policy:-?}" "${sre_slo:-?}"
}

echo -e "${BOLD}The money moment — change '${NAME}' to tier '${NEW_TIER}' (${MODE})${RESET}"
echo "──────────────────────────────────────────────────"

CURRENT_TIER=$(kubectl get service.lockhead.cloud "${NAME}" -n "${NS}" -o jsonpath='{.spec.tier}' 2>/dev/null || echo "")
[[ -z "${CURRENT_TIER}" ]] && die "Service '${NAME}' not found in ${NS}. Onboard it first."

hdr "BEFORE — tier '${CURRENT_TIER}', platform-derived policy:"
snapshot

if [[ "${CURRENT_TIER}" == "${NEW_TIER}" ]]; then
  warn "Service is already tier '${NEW_TIER}'. Pick a different tier to show the change."
  exit 0
fi

# ─── apply the change ─────────────────────────────────────────────────────────
if [[ "${MODE}" == "direct" ]]; then
  hdr "Changing ONE field (direct): spec.tier ${CURRENT_TIER} → ${NEW_TIER}"
  echo -e "${DIM}kubectl patch service.lockhead.cloud ${NAME} -n ${NS} --type=merge -p '{\"spec\":{\"tier\":\"${NEW_TIER}\"}}'${RESET}"
  kubectl patch service.lockhead.cloud "${NAME}" -n "${NS}" \
    --type=merge -p "{\"spec\":{\"tier\":\"${NEW_TIER}\"}}"
  warn "Direct patch: if a svc-${NAME} Argo app exists with selfHeal, it will revert this."
else
  hdr "Changing ONE field in GIT: service-claim.yaml spec.tier ${CURRENT_TIER} → ${NEW_TIER}"
  GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
  [[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./ui.sh)"
  GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

  _pf_pid=""
  if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
    kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
    _pf_pid=$!
  fi
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/tier-${NAME}.XXXXXX")
  trap '[[ -n "${_pf_pid}" ]] && kill "${_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT
  sleep 2

  git -C "${WORK}" init -b main >/dev/null 2>&1
  git -C "${WORK}" config user.email "demo@example.com"
  git -C "${WORK}" config user.name  "Demo"
  git -C "${WORK}" remote add gitea \
    "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${NAME}.git"
  git -C "${WORK}" fetch gitea main >/dev/null 2>&1 \
    && git -C "${WORK}" reset --hard gitea/main >/dev/null 2>&1 \
    || die "Could not fetch repo ${GITEA_ORG}/${NAME}. Is the service GitOps-onboarded?"

  [[ -f "${WORK}/service-claim.yaml" ]] || die "No service-claim.yaml in ${GITEA_ORG}/${NAME} (not GitOps-onboarded — try --direct)."

  # Flip the tier line in the committed claim.
  sed -i '' -E "s/^([[:space:]]*tier:[[:space:]]*).*/\1${NEW_TIER}/" "${WORK}/service-claim.yaml"
  echo -e "${DIM}edit service-claim.yaml → spec.tier: ${NEW_TIER}  (commit + push; Argo CD syncs)${RESET}"
  git -C "${WORK}" add service-claim.yaml
  if git -C "${WORK}" diff --cached --quiet; then
    warn "No change to commit (tier already ${NEW_TIER} in Git)."
  else
    git -C "${WORK}" commit -m "Set ${NAME} tier → ${NEW_TIER}" >/dev/null
    git -C "${WORK}" push gitea main >/dev/null 2>&1 || git -C "${WORK}" push gitea main --force >/dev/null 2>&1
    success "Committed to ${GITEA_ORG}/${NAME} (GitOps source of truth)."
  fi
  # Nudge the per-service Argo app to sync now.
  kubectl annotate application "svc-${NAME}" -n argocd \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
fi

info "Waiting for Crossplane to re-reconcile the registrations..."
expected_window=""
case "${NEW_TIER}" in
  critical) expected_window="24x7" ;;
  standard) expected_window="business-hours" ;;
  experimental) expected_window="none" ;;
esac
for _ in $(seq 1 20); do
  cur=$(kubectl get oncallregistration "oncall-${NAME}" -n sre-system -o jsonpath='{.spec.pagingWindow}' 2>/dev/null || echo "")
  [[ "${cur}" == "${expected_window}" ]] && break
  sleep 2
done

hdr "AFTER — tier '${NEW_TIER}', platform re-derived everything:"
snapshot

echo ""
success "One field changed. The platform re-derived scan cadence, paging, escalation, and SLO"
echo "        across security, SRE, and reporting — no ticket, no manual edits."
echo -e "${BOLD}Show the full picture:${RESET}  ./demo/show-registrations.sh ${NAME}"
