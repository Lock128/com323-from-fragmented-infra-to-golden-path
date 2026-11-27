#!/usr/bin/env bash
# reset-service.sh — undo an onboarding so you can re-run the demo cleanly.
#
# Clears ALL traces of a service across every system the golden path touched:
#   1. Kubernetes   — the Service CR (Crossplane cascade-deletes the Argo CD app
#                     + security/SRE/reporting registrations), plus a label-based
#                     sweep for anything the cascade missed.
#   2. Backstage    — the catalog Location + Component entity that catalog:register
#                     created (THIS is what the old reset missed → orphaned entries
#                     and 409 "Location already exists" on the next onboarding).
#   3. Gitea        — the service's Git repository under the 'lockhead' org.
#
# Usage:  ./demo/reset-service.sh <service-name> <team>
#   e.g.  ./demo/reset-service.sh checkout storefront
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"
TEAM="${2:-storefront}"
NS="team-${TEAM}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${CYAN}Resetting service '${NAME}' (team=${TEAM}) — clearing all traces${RESET}"
echo "──────────────────────────────────────────────────"

# ─── 1. Kubernetes: delete the Service CR + composed resources ───────────────
# Delete the per-service GitOps app FIRST (svc-<name>, created by the portal).
# It has selfHeal + prune, so it would re-apply the Service CR if we deleted the
# CR while it still existed. Removing it also prunes the Service CR it manages.
info "Removing the per-service GitOps app 'svc-${NAME}' (if present)..."
kubectl delete application "svc-${NAME}" -n argocd --ignore-not-found 2>/dev/null || true
sleep 3

# The deploy app (<name>) is created by the Composition WITHOUT Argo CD's resources
# finalizer, so deleting it leaves the workload (Deployment, Service, ConfigMap) behind.
# Add the finalizer first: then removing the app also removes everything it deployed,
# whatever the chart names its objects (the repo name can differ from the service name,
# e.g. service 'legacy' deploys the 'legacy-orders' chart).
if kubectl get application "${NAME}" -n argocd >/dev/null 2>&1; then
  info "Making Argo CD remove the workload together with the app '${NAME}'..."
  kubectl patch application "${NAME}" -n argocd --type=merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null 2>&1 || true
fi
info "Deleting Service claim '${NAME}' (Crossplane cascade-deletes composed resources)..."
kubectl delete service.lockhead.cloud "${NAME}" -n "${NS}" --ignore-not-found 2>/dev/null || true
info "Waiting for the cascade (up to 90s)..."
for _ in $(seq 1 45); do
  kubectl get application "${NAME}" -n argocd >/dev/null 2>&1 || break
  sleep 2
done

# Belt-and-suspenders: remove any leftover composed objects by label.
# The deploy app (<name>) is created by the Composition.
kubectl delete application "${NAME}" -n argocd --ignore-not-found 2>/dev/null || true
# Downstream registrations are now platform-owned CRDs (were ConfigMaps). Delete
# both the typed CRs and any legacy ConfigMaps (older clusters) by the service label.
kubectl delete securityscans,oncallregistrations,reportingentries -A \
  -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
# FinOps (only if the platform was extended via ./demo/add-finops.sh) — delete the
# FinOpsBudget claim, the published FinOpsAllocation, and the status anchor CM.
# ignore-not-found covers the base-platform case where the APIs aren't installed.
kubectl delete finopsbudgets -A -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
kubectl delete finopsallocations -A -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
kubectl delete cm -A -l "lockhead.cloud/registration=finops" -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
# ObservabilitySetup records (only if the Observability Go-function extension is installed).
kubectl delete observabilitysetups -A -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
kubectl delete cm -A -l "lockhead.cloud/service=${NAME}" --ignore-not-found 2>/dev/null || true
kubectl delete deploy,svc -n "${NS}" -l "app=${NAME}" --ignore-not-found 2>/dev/null || true
# Whatever Argo CD deployed for this app, by its tracking label (covers charts whose names
# differ from the service name). Only matters if the app did not clean up after itself.
kubectl delete deploy,svc,cm,ingress -n "${NS}" -l "argocd.argoproj.io/instance=${NAME}" --ignore-not-found 2>/dev/null || true
success "Kubernetes resources removed."

# ─── 2. Backstage: deregister the catalog Location + Component ────────────────
# catalog:register creates a Location entity (and a Component from catalog-info.yaml)
# pointing at the service repo. Deleting the Location cascades to its Component.
# Addressed by Location ID, found by matching the target URL for this repo.
# Needs a Backstage port-forward + a guest token (auth.mode=guest in this demo).
BS_BASE="http://localhost:${BACKSTAGE_PORT}"
GITEA_ORG="lockhead"
REPO_MARKER="/${GITEA_ORG}/${NAME}/"   # unique per-repo substring in the location target

_bs_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${BS_BASE}" 2>/dev/null; then
  info "Starting a temporary Backstage port-forward on :${BACKSTAGE_PORT}..."
  kubectl port-forward -n backstage svc/backstage "${BACKSTAGE_PORT}:7007" >/dev/null 2>&1 &
  _bs_pf_pid=$!
  sleep 4
fi

info "Deregistering '${NAME}' from the Backstage catalog..."
BS_TOKEN=$(curl -s -X POST "${BS_BASE}/api/auth/guest/refresh" \
  -H 'Content-Type: application/json' 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("backstageIdentity",{}).get("token",""))' 2>/dev/null || echo "")

if [[ -z "${BS_TOKEN}" ]]; then
  warn "Could not get a Backstage guest token — skipping catalog cleanup."
  warn "Backstage may not be running (./ui.sh). Catalog entries for '${NAME}' may remain."
else
  # Find every Location whose target points at this service's repo, delete each.
  LOC_IDS=$(curl -s "${BS_BASE}/api/catalog/locations" \
    -H "Authorization: Bearer ${BS_TOKEN}" 2>/dev/null \
    | REPO_MARKER="${REPO_MARKER}" python3 -c '
import sys, json, os
marker = os.environ["REPO_MARKER"]
data = json.load(sys.stdin)
for item in data:
    loc = item.get("data", item)
    if marker in str(loc.get("target", "")):
        print(loc.get("id"))
' 2>/dev/null || echo "")

  if [[ -z "${LOC_IDS}" ]]; then
    success "No Backstage catalog Location for '${NAME}' — nothing to deregister."
  else
    for id in ${LOC_IDS}; do
      code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "${BS_BASE}/api/catalog/locations/${id}" \
        -H "Authorization: Bearer ${BS_TOKEN}" 2>/dev/null || echo "000")
      echo "  deleted Location ${id} → HTTP ${code}"
    done
    success "Backstage catalog deregistered for '${NAME}'."
  fi
fi

[[ -n "${_bs_pf_pid}" ]] && kill "${_bs_pf_pid}" >/dev/null 2>&1 || true

# ─── 3. Gitea: delete the service repository ─────────────────────────────────
info "Deleting the Gitea repository '${GITEA_ORG}/${NAME}'..."
GITEA_USER="giteaAdmin"   # auth user
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

if [[ -n "${GITEA_PASS}" ]]; then
  # Ensure Gitea is reachable on :${GITEA_PORT} (ui.sh usually has this forwarded).
  _gitea_pf_pid=""
  if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
    kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
    _gitea_pf_pid=$!
    sleep 3
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${NAME}" \
    -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null || echo "000")
  if [[ "${code}" == "204" ]]; then
    success "Gitea repository '${GITEA_ORG}/${NAME}' deleted."
  elif [[ "${code}" == "404" ]]; then
    success "Gitea repository '${GITEA_ORG}/${NAME}' not found — already gone."
  else
    warn "Unexpected HTTP ${code} deleting the Gitea repo — check it manually at ${GITEA_LOCAL}/${GITEA_ORG}/${NAME}"
  fi
  [[ -n "${_gitea_pf_pid}" ]] && kill "${_gitea_pf_pid}" >/dev/null 2>&1 || true
else
  warn "Could not read Gitea password — skipping repo delete. Repo for '${NAME}' may remain."
fi

# ─── 4. GitOps source is handled above ───────────────────────────────────────
# Every GitOps onboarding path (portal, onboard-service.sh, onboard-existing.sh)
# keeps the Service CR as service-claim.yaml in the SERVICE's OWN repo, synced by
# the per-service 'svc-<name>' Argo app. Both are already gone:
#   • svc-<name> Argo app  → deleted FIRST (step 1), so it stops re-applying.
#   • the service repo      → deleted in step 3, removing the claim from Git.
# So there is no separate GitOps file to clean up here.
#
# Belt-and-suspenders for the DEPRECATED central-repo model (older clusters that
# used platform-api/services/): drop that Argo app if it lingers.
kubectl delete application platform-services -n argocd --ignore-not-found 2>/dev/null || true

echo ""
success "Reset complete — '${NAME}' can be onboarded again cleanly (no orphaned catalog/repo/GitOps CR)."
