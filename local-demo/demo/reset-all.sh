#!/usr/bin/env bash
# reset-all.sh — reset the WHOLE demo back to a freshly-bootstrapped platform.
#
# This is the "put everything back for the next rehearsal / the next talk" button.
# It does NOT touch the cluster, Crossplane, Backstage, Gitea or the platform API
# itself — only the demo artifacts you create DURING a talk:
#
#   1. Every onboarded service  — for each Service CR found in any team-* namespace
#      it runs reset-service.sh, which clears the Service CR + composed resources,
#      the Gitea repo, the Backstage catalog entry and the per-service GitOps app.
#   2. The FinOps extension      — reverted to the base platform (if it was added).
#   3. The Observability (Go)    — reverted to the base platform (if it was added).
#
# After this the Live view shows zero services and the platform is back to the
# three baseline registrations. Re-onboard from the portal to start again.
#
# Usage:  ./demo/reset-all.sh            # reset everything
#         ./demo/reset-all.sh --keep-extensions   # services only, leave FinOps/Obs
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

KEEP_EXT=0
[[ "${1:-}" == "--keep-extensions" ]] && KEEP_EXT=1

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Reset the WHOLE demo — back to a clean platform${RESET}"
echo "──────────────────────────────────────────────────"

# ─── 1. Revert the optional extensions FIRST ─────────────────────────────────
# Do this before deleting services so the Composition is back to the base set of
# registrations while the per-service cascade runs (avoids a brief window where a
# service references an extension that's mid-removal).
if [[ "${KEEP_EXT}" -eq 0 ]]; then
  # Observability Go-function extension — only if its API is installed.
  if kubectl get crd observabilitysetups.platform.lockhead.cloud >/dev/null 2>&1; then
    info "Reverting the Observability (Go function) extension..."
    bash "${SCRIPT_DIR}/add-observability.sh" --remove || warn "add-observability.sh --remove reported an issue."
  else
    info "Observability extension not installed — skipping."
  fi
  # FinOps extension — only if its API is installed.
  if kubectl get crd finopsallocations.platform.lockhead.cloud >/dev/null 2>&1; then
    info "Reverting the FinOps extension..."
    bash "${SCRIPT_DIR}/add-finops.sh" --remove || warn "add-finops.sh --remove reported an issue."
  else
    info "FinOps extension not installed — skipping."
  fi
else
  info "--keep-extensions: leaving FinOps / Observability in place."
fi

# ─── 2. Reset every onboarded service ────────────────────────────────────────
# Discover each Service CR as "<namespace> <name>"; derive the team from the
# namespace (team-<team>). reset-service.sh takes <name> <team>.
info "Discovering onboarded services..."
SERVICES=$(kubectl get services.lockhead.cloud -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ -z "${SERVICES//[[:space:]]/}" ]]; then
  success "No onboarded services found — nothing to reset."
else
  COUNT=$(printf '%s\n' "${SERVICES}" | grep -c . || true)
  info "Found ${COUNT} service(s) to reset."
  while read -r ns name; do
    [[ -z "${name}" ]] && continue
    team="${ns#team-}"                       # team-storefront -> storefront
    echo ""
    info "── Resetting '${name}' (team=${team}) ──"
    bash "${SCRIPT_DIR}/reset-service.sh" "${name}" "${team}" || warn "reset-service.sh failed for '${name}' — continuing."
  done <<< "${SERVICES}"
fi

# ─── 3. Sweep any stragglers the cascades missed ─────────────────────────────
# Label-based cleanup across all namespaces, in case a service was partially
# onboarded (CR gone but a registration lingered). Harmless if nothing matches.
info "Final sweep for orphaned registrations..."
kubectl delete securityscans,oncallregistrations,reportingentries -A \
  -l lockhead.cloud/managed-by=crossplane --ignore-not-found >/dev/null 2>&1 || true

# ─── 4. Re-sync the LOCAL GitOps checkout to the source of truth (Gitea) ─────
# We do GitOps: Gitea is the source of truth, Argo CD reconciles from it, and the
# extension reverts above already pushed the baseline back to Gitea. But the local
# working copy setup_gitops.sh pushes from (repos/platform-api) may still hold the
# stale extended state — a later setup_gitops.sh run would re-push it. Re-point the
# local checkout at Gitea's current HEAD so local == source of truth. (No git stash:
# a hard reset to the remote is the intended "match the source of truth" op.)
LOCAL_PLATFORM_API="${SCRIPT_DIR}/../repos/platform-api"
if [[ -d "${LOCAL_PLATFORM_API}/.git" ]]; then
  info "Re-syncing local GitOps checkout (repos/platform-api) to Gitea HEAD..."
  # Ensure Gitea is reachable on :${GITEA_PORT} (the remote points there).
  _rs_pf_pid=""
  if ! curl -s -o /dev/null --max-time 3 "http://localhost:${GITEA_PORT}/api/v1/version" 2>/dev/null; then
    kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
    _rs_pf_pid=$!
    sleep 3
  fi
  if git -C "${LOCAL_PLATFORM_API}" fetch gitea main >/dev/null 2>&1; then
    git -C "${LOCAL_PLATFORM_API}" reset --hard gitea/main >/dev/null 2>&1 \
      && success "Local checkout reset to Gitea HEAD (baseline platform)." \
      || warn "Could not hard-reset the local checkout — remove repos/platform-api to force a clean re-init."
    # Drop any untracked leftovers (e.g. finops files that were added locally).
    git -C "${LOCAL_PLATFORM_API}" clean -fd >/dev/null 2>&1 || true
  else
    warn "Could not fetch from Gitea — local checkout left as-is. (Is Gitea up / ui.sh running?)"
  fi
  [[ -n "${_rs_pf_pid}" ]] && kill "${_rs_pf_pid}" >/dev/null 2>&1 || true
else
  info "No local repos/platform-api checkout — nothing to re-sync (setup_gitops.sh re-creates it)."
fi

echo ""
success "Demo reset complete — the Live view should now show zero services."
echo "  Gitea + local GitOps checkout are back to the baseline platform (extensions reverted)."
echo "  Re-onboard from Backstage (Create → 'Onboard a new service') or ./demo/onboard-service.sh <name> <team>."
