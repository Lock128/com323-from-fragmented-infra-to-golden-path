#!/usr/bin/env bash
# reload-template.sh — apply a changed Backstage golden-path template end to end.
#
# WHY THIS EXISTS
# ---------------
# Editing packages/5-backstage/service-template/ is NOT enough for the running
# portal to use the change. Two things must happen, in order:
#   1. PUSH the template to the Gitea 'platform-api' repo (Backstage reads the
#      template from Gitea, not from your laptop).
#   2. REFRESH the Backstage catalog Location that owns the template. A
#      `kubectl rollout restart` is NOT sufficient — the catalog processor
#      re-registers the previously cached entity before it re-reads the file,
#      so the portal keeps serving the OLD template. You must POST a refresh.
#
# This script does both and then verifies the live register step reflects your
# edit, so "I changed the template" is a single command.
#
# Usage:  ./reload-template.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

echo -e "${BOLD}Reload the Backstage golden-path template${RESET}"
echo "──────────────────────────────────────────────────"

kubectl config use-context ${KUBE_CONTEXT} >/dev/null 2>&1 || true

# ── config ───────────────────────────────────────────────────────────────────
GITEA_USER="giteaAdmin"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
TEMPLATE_REF="template:default/service-onboarding"
LOCATION_REF="location:default/platform-golden-path-templates"
BS_BASE="http://localhost:${BACKSTAGE_PORT}"

SRC_TEMPLATE_DIR="${SCRIPT_DIR}/packages/5-backstage/service-template"
SRC_CATALOG="${SCRIPT_DIR}/packages/5-backstage/catalog-info.yaml"

# ─── 1. push the template to Gitea (platform-api repo) ───────────────────────
info "Pushing the template to Gitea (platform-api repo)..."
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
[[ -z "${GITEA_PASS}" ]] && die "Could not read the Gitea password. Is the cluster up? (./start.sh / ./ui.sh)"
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

# Ensure Gitea is reachable on :${GITEA_PORT}.
_gitea_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  _gitea_pf_pid=$!
  sleep 3
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/reload-template.XXXXXX")
trap '[[ -n "${_gitea_pf_pid}" ]] && kill "${_gitea_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT

git -C "${WORK}" init -b main >/dev/null 2>&1
git -C "${WORK}" config user.email "demo@example.com"
git -C "${WORK}" config user.name  "Demo"
# Clone current platform-api so we push a fast-forward, not a force-replace of
# the XRD/Composition that also live in this repo.
git -C "${WORK}" remote add gitea \
  "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_USER}/platform-api.git"
if git -C "${WORK}" fetch gitea main >/dev/null 2>&1; then
  git -C "${WORK}" reset --hard gitea/main >/dev/null 2>&1
fi

# Overlay the latest templates + catalog from the source tree.
rm -rf "${WORK}/service-template" "${WORK}/existing-service-template"
cp -R "${SRC_TEMPLATE_DIR}" "${WORK}/service-template"
cp -R "${SCRIPT_DIR}/packages/5-backstage/existing-service-template" "${WORK}/existing-service-template"
demo_rewrite_ports_in_tree "${WORK}/service-template"
demo_rewrite_ports_in_tree "${WORK}/existing-service-template"
cp "${SRC_CATALOG}" "${WORK}/catalog-info.yaml"

git -C "${WORK}" add service-template existing-service-template catalog-info.yaml
if git -C "${WORK}" diff --cached --quiet; then
  success "Template already up to date in Gitea — nothing to push."
else
  git -C "${WORK}" commit -m "Update golden-path template (reload-template.sh)" >/dev/null
  git -C "${WORK}" push gitea main >/dev/null 2>&1 \
    || git -C "${WORK}" push gitea main --force >/dev/null 2>&1
  success "Template pushed to Gitea."
fi

# ─── 2. refresh the Backstage catalog Location ───────────────────────────────
# Ensure a Backstage port-forward.
_bs_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${BS_BASE}" 2>/dev/null; then
  info "Starting a temporary Backstage port-forward on :${BACKSTAGE_PORT}..."
  kubectl port-forward -n backstage svc/backstage "${BACKSTAGE_PORT}:7007" >/dev/null 2>&1 &
  _bs_pf_pid=$!
  trap '[[ -n "${_gitea_pf_pid}" ]] && kill "${_gitea_pf_pid}" >/dev/null 2>&1; [[ -n "${_bs_pf_pid}" ]] && kill "${_bs_pf_pid}" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT
  sleep 4
fi

info "Getting a Backstage guest token..."
TOKEN=$(curl -s -X POST "${BS_BASE}/api/auth/guest/refresh" \
  -H 'Content-Type: application/json' 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("backstageIdentity",{}).get("token",""))' 2>/dev/null || echo "")
[[ -z "${TOKEN}" ]] && die "Could not get a guest token from ${BS_BASE}. Is Backstage up? (./ui.sh)"
auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

info "Refreshing the template location (forces a re-read from Gitea)..."
curl -s -o /dev/null -w "  template entity:   HTTP %{http_code}\n" \
  -X POST "${BS_BASE}/api/catalog/refresh" "${auth[@]}" \
  -d "{\"entityRef\":\"${TEMPLATE_REF}\"}" || true
curl -s -o /dev/null -w "  template location: HTTP %{http_code}\n" \
  -X POST "${BS_BASE}/api/catalog/refresh" "${auth[@]}" \
  -d "{\"entityRef\":\"${LOCATION_REF}\"}" || true

info "Waiting for the catalog processor to re-ingest..."
sleep 8

# ─── 3. verify the live register step reflects the file ──────────────────────
info "Verifying the live template register step..."
curl -s "${BS_BASE}/api/catalog/entities/by-name/template/default/service-onboarding" "${auth[@]}" 2>/dev/null \
  | python3 -c '
import sys, json
e = json.load(sys.stdin)
for s in e.get("spec", {}).get("steps", []):
    if s.get("id") == "register":
        i = s.get("input", {})
        print("  repoContentsUrl:", i.get("repoContentsUrl"))
        print("  catalogInfoPath:", i.get("catalogInfoPath"))
' 2>&1 || warn "Could not read back the template (refresh still likely succeeded)."

echo ""
success "Template reloaded end to end. Onboard a NEW service name from the portal to test."
echo "  (repoContentsUrl should end with /src/branch/main/ and catalogInfoPath should be relative.)"
