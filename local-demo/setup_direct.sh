#!/usr/bin/env bash
# Direct mode setup — applies the platform API with kubectl instead of GitOps.
# Run this once after start.sh as an alternative to setup_gitops.sh.
#
# The Service composition still creates an Argo CD Application per service (that
# is the CD engine), but the XRD + Composition themselves are applied directly
# here rather than synced from Gitea.
#
# After this:  use demo/onboard-service.sh + show-*.sh to drive the demo.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="${SCRIPT_DIR}/packages"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

SETUP_START=$(date +%s)

echo -e "${BOLD}re:Invent 2026 — Direct Mode Setup (no GitOps)${RESET}"
echo "──────────────────────────────────────────────────"

# ─── 0. Crossplane pod CA trust ───────────────────────────────────────────────
# Ensures the crossplane pod trusts the proxy CA even if start.sh predates this fix.
patch_crossplane_ca() {
  if kubectl get deployment crossplane -n crossplane-system \
      -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null \
      | grep -q "SSL_CERT_DIR"; then
    return 0
  fi
  local tmp_cert
  tmp_cert=$(mktemp /tmp/zscaler-crossplane.XXXXXX.crt)
  trap "rm -f ${tmp_cert}" RETURN
  if ! docker cp ${DEMO_NAME}-control-plane:/usr/local/share/ca-certificates/zscaler.crt "${tmp_cert}" 2>/dev/null; then
    return 0
  fi
  info "Patching Crossplane deployment to trust proxy CA..."
  kubectl create configmap zscaler-ca -n crossplane-system \
    --from-file=zscaler.crt="${tmp_cert}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl patch deployment crossplane -n crossplane-system --type=strategic --patch='{
    "spec":{"template":{"spec":{
      "volumes":[{"name":"zscaler-ca","configMap":{"name":"zscaler-ca"}}],
      "containers":[{"name":"crossplane",
        "env":[{"name":"SSL_CERT_DIR","value":"/etc/ssl/certs:/etc/ssl/custom-ca"}],
        "volumeMounts":[{"name":"zscaler-ca","mountPath":"/etc/ssl/custom-ca","readOnly":true}]
      }]
    }}}}'
  kubectl rollout status deployment/crossplane -n crossplane-system --timeout=90s
  success "Crossplane proxy CA injected."
}
patch_crossplane_ca

# ─── 1. XRD ───────────────────────────────────────────────────────────────────
info "Applying the Service XRD..."
kubectl apply -f "${PACKAGES}/2-platform-api/xrds/"

info "Waiting for the XRD to be Established..."
kubectl wait xrd/xservices.lockhead.cloud --for=condition=Established --timeout=60s
success "Service API established."

# The Composition creates platform-owned downstream CRs (SecurityScan,
# OnCallRegistration, ReportingEntry) — wait for those CRDs to be Established too,
# or the first reconcile fails until the API server registers them.
info "Waiting for the downstream CRDs to be Established..."
for crd in securityscans.platform.lockhead.cloud oncallregistrations.platform.lockhead.cloud reportingentries.platform.lockhead.cloud; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=60s 2>/dev/null \
    || warn "CRD ${crd} not Established yet — Crossplane will retry."
done
success "Downstream CRDs established."

# ─── 2. Composition ────────────────────────────────────────────────────────────
info "Applying the service-onboarding Composition..."
kubectl apply -f "${PACKAGES}/2-platform-api/compositions/"
success "Composition applied."

# ─── 3. Namespaces ──────────────────────────────────────────────────────────────
info "Creating the demo team namespace (team-storefront)..."
kubectl create namespace team-storefront --dry-run=client -o yaml | kubectl apply -f -
success "team-storefront namespace ready."

# ─── 4. Backstage golden-path template ──────────────────────────────────────────
# Push the Backstage Software Template + skeleton to Gitea so the developer portal
# shows "Onboard a new service". Backstage's catalog location points at
# platform-api/catalog-info.yaml in Gitea.
info "Pushing the golden-path template to Gitea platform-api repo..."
GITEA_USER="giteaAdmin"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential \
  -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

if [[ -n "${GITEA_PASS}" ]]; then
  if ! curl -s -o /dev/null "${GITEA_LOCAL}/api/v1/user" -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null; then
    # Local port ${GITEA_PORT} (matches ui.sh + GITEA_LOCAL) → in-cluster Gitea svc :3000.
    kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
    sleep 3
  fi

  curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/user/repos" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"name":"platform-api","description":"Platform API — Service XRD + Composition + golden-path template","auto_init":true,"default_branch":"main"}' || true

  # Ensure the 'lockhead' ORG exists — service repos created by the Backstage
  # golden-path template (publish:gitea) must be owned by an org, not the
  # giteaAdmin user (the action only supports POST /api/v1/orgs/{owner}/repos).
  info "Ensuring Gitea organization 'lockhead' exists (for service repos)..."
  curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/admin/users/${GITEA_USER}/orgs" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"username":"lockhead","full_name":"lockhead.cloud platform","visibility":"public"}' || true

  GITEA_PASS_ENC=$(python3 -c \
    "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" \
    "${GITEA_PASS}")
  CATALOG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/backstage-catalog.XXXXXX")
  trap "rm -rf ${CATALOG_TMP}" EXIT

  git -C "$(dirname "${CATALOG_TMP}")" init -b main "$(basename "${CATALOG_TMP}")" 2>/dev/null || \
    (mkdir -p "${CATALOG_TMP}" && git -C "${CATALOG_TMP}" init -b main)
  git -C "${CATALOG_TMP}" config user.email "demo@example.com"
  git -C "${CATALOG_TMP}" config user.name  "Demo"
  git -C "${CATALOG_TMP}" remote add gitea \
    "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_USER}/platform-api.git"

  cp "${SCRIPT_DIR}/packages/5-backstage/catalog-info.yaml" "${CATALOG_TMP}/"
  cp -R "${SCRIPT_DIR}/packages/5-backstage/service-template" "${CATALOG_TMP}/"
  demo_rewrite_ports_in_tree "${CATALOG_TMP}/service-template"

  git -C "${CATALOG_TMP}" add .
  git -C "${CATALOG_TMP}" commit -m "Backstage catalog: service-onboarding golden-path template"
  git -C "${CATALOG_TMP}" push gitea main --force 2>/dev/null && \
    success "Golden-path template pushed to Gitea platform-api." || \
    warn "Could not push template — Backstage will retry automatically."
else
  warn "Could not read Gitea password — skipping template push."
fi

total=$(( $(date +%s) - SETUP_START ))
echo -e "\n${BOLD}${GREEN}✓ Direct mode setup complete in $(( total / 60 ))m $(( total % 60 ))s${RESET}"
echo ""
echo -e "${BOLD}Onboard a service (scripted path):${RESET}"
echo "  ./demo/onboard-service.sh checkout storefront"
echo "  ./demo/show-repo.sh checkout"
echo "  ./demo/show-deploy.sh checkout storefront"
echo "  ./demo/show-registrations.sh checkout"
echo ""
echo -e "${BOLD}Reset between runs:${RESET}"
echo "  ./demo/reset-service.sh checkout storefront"
echo ""
