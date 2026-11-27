#!/usr/bin/env bash
# show-drift.sh — Act 4: the platform reasserts its intent.
# Someone DELETES a resource the platform owns (the Argo CD Application the
# Composition created). Because the desired state lives in a Crossplane Object,
# the platform recreates it — you can't delete your way out of the platform's
# intent.
#
# HONEST NOTE FOR THE DEMO: provider-kubernetes (v0.14.x, watch disabled) only
# reconciles on a poll interval, so we explicitly KICK the managing Crossplane
# Object to reconcile NOW — the recreation then happens in ~2s, crisp and
# reproducible on stage. (In prod you'd tune the provider poll interval / enable
# watch so this is automatic; here we trigger it for a tight demo beat.)
#
# We demonstrate DELETE → RECREATE rather than field-level drift because this
# provider version reliably recreates a missing object, but does not revert an
# in-place hand-edit — so this is the honest, repeatable version of the story.
#
# Usage:  ./demo/show-drift.sh <service-name>
#   e.g.  ./demo/show-drift.sh checkout
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
hdr()     { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}The platform reasserts its intent — '${NAME}' Argo CD Application${RESET}"
echo -e "${DIM}Delete the Application the platform owns; the control plane recreates it.${RESET}"
echo "──────────────────────────────────────────────────"

if ! kubectl get application "${NAME}" -n argocd >/dev/null 2>&1; then
  warn "Argo CD Application '${NAME}' not found. Onboard the service first."
  exit 1
fi

# Find the Crossplane Object that manages this service's Argo Application.
find_managing_object() {
  kubectl get object.kubernetes.crossplane.io -o name 2>/dev/null | while read -r o; do
    local k n
    k=$(kubectl get "$o" -o jsonpath='{.spec.forProvider.manifest.kind}' 2>/dev/null)
    n=$(kubectl get "$o" -o jsonpath='{.spec.forProvider.manifest.metadata.name}' 2>/dev/null)
    if [[ "$k" == "Application" && "$n" == "${NAME}" ]]; then echo "$o"; return; fi
  done
}

OBJ=$(find_managing_object)
[[ -z "${OBJ}" ]] && { warn "Could not find the Crossplane Object managing '${NAME}'."; exit 1; }

hdr "BEFORE — the Application exists, owned by the platform"
kubectl get application "${NAME}" -n argocd \
  -o custom-columns='NAME:.metadata.name,PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null
echo -e "  ${DIM}managed by: ${OBJ}${RESET}"

hdr "Someone deletes the Application the platform owns"
echo -e "${DIM}kubectl delete application ${NAME} -n argocd${RESET}"
kubectl delete application "${NAME}" -n argocd >/dev/null 2>&1
echo -e "  ${YELLOW}Application deleted.${RESET}"

hdr "The control plane reasserts its intent — kick the managing Object to reconcile now"
echo -e "${DIM}kubectl annotate ${OBJ} demo/reconcile=\$(date +%s) --overwrite${RESET}"
kubectl annotate "${OBJ}" "demo/reconcile=$(date +%s)" --overwrite >/dev/null 2>&1 || true

info "Waiting for the platform to recreate it..."
RECREATED=""
for _ in $(seq 1 20); do
  if kubectl get application "${NAME}" -n argocd >/dev/null 2>&1; then RECREATED="yes"; break; fi
  sleep 2
done

hdr "AFTER — the platform recreated it"
if [[ -n "${RECREATED}" ]]; then
  kubectl get application "${NAME}" -n argocd \
    -o custom-columns='NAME:.metadata.name,PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null
  echo ""
  success "Recreated. You can't delete your way out of the platform's declared intent."
else
  warn "Not recreated yet — the provider poll can lag. Nudge again:"
  echo "  kubectl annotate ${OBJ} demo/reconcile=\$(date +%s) --overwrite"
fi
echo -e "${BOLD}Talking point:${RESET} the Service CR is the source of truth. Delete a downstream"
echo "resource and the control plane puts it right back — no human remediation."
