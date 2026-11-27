#!/usr/bin/env bash
# Installs the platform API and wires the golden-path template into Backstage:
#
#   One Gitea repo:
#     platform-api   ← Service XRD + Composition + Backstage golden-path template
#
#   Two ArgoCD Applications (from packages/4-gitops/):
#     platform-xrds          → platform-api.git / packages/2-platform-api/xrds/
#     platform-compositions  → platform-api.git / packages/2-platform-api/compositions/
#
#   Per-service repos are created ON DEMAND by the Backstage onboarding template
#   (publish:gitea) when a developer onboards a service — not here.
#
# Run ONCE after start.sh. Safe to re-run — all steps are idempotent.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

GITOPS_START=$(date +%s)
GITOPS_STEP=0
GITOPS_TOTAL=5

elapsed_fmt() { local s=$(( $(date +%s) - GITOPS_START )); printf '%d:%02d' $(( s/60 )) $(( s%60 )); }
print_step() {
  (( GITOPS_STEP++ )) || true
  local bar="" i=0
  while [[ $i -lt $GITOPS_STEP  ]]; do bar+="█"; (( i++ )); done
  while [[ $i -lt $GITOPS_TOTAL ]]; do bar+="░"; (( i++ )); done
  echo -e "\n${BOLD}${CYAN}[$(elapsed_fmt)]  [${GITOPS_STEP}/${GITOPS_TOTAL}]  ${bar}${RESET}"
  echo -e "${BOLD}▶ $1${RESET}  ${DIM}(expected: ~$2)${RESET}"
}

# ─── resolve credentials ──────────────────────────────────────────────────────
GITEA_USER="giteaAdmin"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential \
  -o jsonpath='{.data.password}' | base64 -d)
GITEA_LOCAL="http://localhost:${GITEA_PORT}"
GITEA_INTERNAL="http://my-gitea-http.gitea.svc.cluster.local:3000"

# URL-encode password — Gitea generates passwords with special chars
# (brackets, semicolons, etc.) that break git URL parsing
GITEA_PASS_ENC=$(python3 -c \
  "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" \
  "${GITEA_PASS}")

REPOS_DIR="${SCRIPT_DIR}/repos"
mkdir -p "${REPOS_DIR}"

# ─── crossplane pod CA trust ──────────────────────────────────────────────────
# Ensures the crossplane pod trusts the proxy CA even if start.sh predates this fix.
_patch_crossplane_ca() {
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
_patch_crossplane_ca

# ─── registry pull fix (Crossplane + containerd → Gitea over HTTPS ingress) ───
# The Go composition function (packages/4-observability) is pulled from the
# in-cluster Gitea OCI registry. That registry is plain HTTP, which Crossplane
# v2.4.0 can't pull from directly. fix_registry_pull.sh routes the pull over the
# idpbuilder HTTPS ingress (CoreDNS + CA trust + pull secret + containerd mirror).
# Idempotent + harmless if the observability extension is never added.
if [[ -x "${SCRIPT_DIR}/fix_registry_pull.sh" ]]; then
  bash "${SCRIPT_DIR}/fix_registry_pull.sh" || warn "fix_registry_pull.sh reported an issue — the Go function install may need it re-run."
fi

# ─── helper: ensure the 'lockhead' Gitea ORG exists (idempotent) ──────────────
# Service repos created by the Backstage golden-path template MUST live under a
# Gitea organization: the publish:gitea scaffolder action (v0.1.12) only creates
# repos via POST /api/v1/orgs/{owner}/repos — there is no user-repo path. Pointing
# the template's owner at the giteaAdmin USER fails with
#   "GetOrgByName … user redirect does not exist".
# The platform-api repo itself stays a normal user repo (giteaAdmin/platform-api);
# only the per-service repos use this org.
GITEA_ORG="lockhead"
ensure_gitea_org() {
  info "Ensuring Gitea organization '${GITEA_ORG}' exists (for service repos)..."
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_LOCAL}/api/v1/admin/users/${GITEA_USER}/orgs" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${GITEA_ORG}\",\"full_name\":\"lockhead.cloud platform\",\"visibility\":\"public\"}")
  if [[ "${HTTP}" == "201" ]]; then
    success "Organization '${GITEA_ORG}' created."
  elif [[ "${HTTP}" == "422" || "${HTTP}" == "409" ]]; then
    success "Organization '${GITEA_ORG}' already exists — skipping."
  else
    warn "Unexpected HTTP ${HTTP} creating org '${GITEA_ORG}' — the Backstage onboarding may fail until it exists."
  fi
}

# ─── helper: create a Gitea repo (idempotent) ─────────────────────────────────
create_gitea_repo() {
  local name=$1 description=$2
  info "Creating Gitea repository '${name}'..."
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_LOCAL}/api/v1/user/repos" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\",\"description\":\"${description}\",\"auto_init\":true,\"default_branch\":\"main\"}")
  if [[ "${HTTP}" == "201" ]]; then
    success "Repository '${name}' created."
  elif [[ "${HTTP}" == "409" ]]; then
    success "Repository '${name}' already exists — skipping."
  else
    echo "Unexpected HTTP ${HTTP} creating repo '${name}' — check Gitea at ${GITEA_LOCAL}"
    exit 1
  fi
}

# ─── helper: init a local git repo and wire remote ────────────────────────────
init_local_repo() {
  local dir=$1 remote_repo=$2
  local push_url="http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_USER}/${remote_repo}.git"

  if [[ ! -d "${dir}/.git" ]]; then
    git -C "$(dirname "${dir}")" init -b main "$(basename "${dir}")" 2>/dev/null || \
      (mkdir -p "${dir}" && git -C "${dir}" init -b main)
    git -C "${dir}" commit --allow-empty -m "init"
  fi

  # Set or update the 'gitea' remote (with credentials baked in for demo pushes)
  if git -C "${dir}" remote get-url gitea >/dev/null 2>&1; then
    git -C "${dir}" remote set-url gitea "${push_url}"
  else
    git -C "${dir}" remote add gitea "${push_url}"
  fi

  # Set user identity for commits inside this repo
  git -C "${dir}" config user.email "demo@example.com" 2>/dev/null || true
  git -C "${dir}" config user.name  "Demo" 2>/dev/null || true

  success "Local repo at ${dir} → gitea: ${GITEA_LOCAL}/${GITEA_USER}/${remote_repo}"
}

# ─── helper: push a local repo ────────────────────────────────────────────────
push_repo() {
  local dir=$1
  git -C "${dir}" push gitea main --force
}

# ─── port-forward Gitea if not reachable ─────────────────────────────────────
if ! curl -s -o /dev/null "${GITEA_LOCAL}/api/v1/user" \
    -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null; then
  info "Starting Gitea port-forward..."
  # Local port ${GITEA_PORT} (matches ui.sh + GITEA_LOCAL) → in-cluster Gitea svc :3000.
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  sleep 3
fi

echo -e "${BOLD}re:Invent 2026 — Platform API + GitOps Setup${RESET}"
echo "──────────────────────────────────────────────────"

# ─── 1. Create the platform-api Gitea repository + the service-repo org ──────
print_step "Creating platform-api repo + 'lockhead' org (for service repos)" "instant"
create_gitea_repo "platform-api" "Platform API — Service XRD, Composition, Backstage golden-path template"
ensure_gitea_org

# ─── 2. Populate + push platform-api ─────────────────────────────────────────
print_step "Pushing platform API (XRD + Composition + Backstage template)" "10 s"
info "Setting up repos/platform-api/ ..."
init_local_repo "${REPOS_DIR}/platform-api" "platform-api"

# Mirror the packages/ layout so the ArgoCD apps (which point at
# packages/2-platform-api/{xrds,compositions}) find the manifests.
mkdir -p "${REPOS_DIR}/platform-api/packages/2-platform-api/xrds"
mkdir -p "${REPOS_DIR}/platform-api/packages/2-platform-api/compositions"
cp "${SCRIPT_DIR}/packages/2-platform-api/xrds/"*.yaml \
   "${REPOS_DIR}/platform-api/packages/2-platform-api/xrds/"
cp "${SCRIPT_DIR}/packages/2-platform-api/compositions/"*.yaml \
   "${REPOS_DIR}/platform-api/packages/2-platform-api/compositions/"

# Backstage catalog + the service-onboarding golden-path template + skeleton,
# so the "Onboard a new service" template appears in the portal.
cp "${SCRIPT_DIR}/packages/5-backstage/catalog-info.yaml" "${REPOS_DIR}/platform-api/"
rm -rf "${REPOS_DIR}/platform-api/service-template" "${REPOS_DIR}/platform-api/existing-service-template"
cp -R "${SCRIPT_DIR}/packages/5-backstage/service-template" "${REPOS_DIR}/platform-api/"
cp -R "${SCRIPT_DIR}/packages/5-backstage/existing-service-template" "${REPOS_DIR}/platform-api/"
# The templates keep the original port numbers; write this instance's into the copies.
demo_rewrite_ports_in_tree "${REPOS_DIR}/platform-api/service-template"
demo_rewrite_ports_in_tree "${REPOS_DIR}/platform-api/existing-service-template"

git -C "${REPOS_DIR}/platform-api" add packages/ catalog-info.yaml service-template/ existing-service-template/
if git -C "${REPOS_DIR}/platform-api" diff --cached --quiet; then
  success "platform-api: already up to date."
else
  git -C "${REPOS_DIR}/platform-api" commit -m "Platform API: Service XRD + Composition + golden-path template"
fi
push_repo "${REPOS_DIR}/platform-api"
success "platform-api pushed to Gitea (XRD + Composition + Backstage template)."

# ─── 3. Register Gitea with ArgoCD ───────────────────────────────────────────
print_step "Registering Gitea repo with ArgoCD" "10 s"
info "Registering Gitea with ArgoCD..."
kubectl create secret generic gitea-repos \
  --namespace=argocd \
  --from-literal=type=git \
  --from-literal=url="${GITEA_INTERNAL}" \
  --from-literal=username="${GITEA_USER}" \
  --from-literal=password="${GITEA_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret gitea-repos -n argocd \
  argocd.argoproj.io/secret-type=repository --overwrite
success "ArgoCD repository secret created."

# ─── 4. Create the platform ArgoCD Applications (XRD + Composition) ──────────
print_step "Installing the platform API via ArgoCD (XRD + Composition)" "30 s"
info "Creating ArgoCD Applications from packages/4-gitops/..."
kubectl apply -f "${SCRIPT_DIR}/packages/4-gitops/platform-xrds-app.yaml"
kubectl apply -f "${SCRIPT_DIR}/packages/4-gitops/platform-compositions-app.yaml"
success "2 ArgoCD Applications created (platform-xrds, platform-compositions)."

info "Triggering initial sync..."
for app in platform-xrds platform-compositions; do
  kubectl annotate application "${app}" \
    -n argocd argocd.argoproj.io/refresh=normal --overwrite 2>/dev/null || true
done

# ─── 5. Wait for the Service XRD to be established ───────────────────────────
print_step "Waiting for the Service API to come online" "30 s"
info "Waiting for XRD xservices.lockhead.cloud to be Established..."
kubectl wait xrd/xservices.lockhead.cloud --for=condition=Established --timeout=120s 2>/dev/null \
  && success "Service API is live — 'kubectl get services.lockhead.cloud' now works." \
  || warn "XRD not Established yet — ArgoCD may still be syncing. Re-check in a moment."

# The Composition fans out into platform-owned CRDs (SecurityScan,
# OnCallRegistration, ReportingEntry) — also synced by the platform-xrds app.
# Wait for them so the first onboarding's registrations don't error on a missing API.
info "Waiting for the downstream platform CRDs to be Established..."
for crd in securityscans.platform.lockhead.cloud oncallregistrations.platform.lockhead.cloud reportingentries.platform.lockhead.cloud; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=120s 2>/dev/null \
    || warn "CRD ${crd} not Established yet — ArgoCD may still be syncing."
done

# ─── done ─────────────────────────────────────────────────────────────────────
total=$(( $(date +%s) - GITOPS_START ))
echo -e "\n${BOLD}${GREEN}✓ setup_gitops.sh complete in $(( total / 60 ))m $(( total % 60 ))s${RESET}"
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   Platform API is live — the golden path is ready           ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Gitea:${RESET}"
echo "  ${GITEA_LOCAL}/${GITEA_USER}/platform-api   ← Service XRD + Composition + template"
echo "  (each onboarded service gets its OWN repo, created on demand by Backstage)"
echo ""
echo -e "${BOLD}ArgoCD:${RESET}  http://localhost:${ARGOCD_PORT}"
echo "  platform-xrds          → platform-api/packages/2-platform-api/xrds/"
echo "  platform-compositions  → platform-api/packages/2-platform-api/compositions/"
echo "  <service>              → created per service by the onboarding Composition"
echo ""
echo -e "${BOLD}Run the golden-path demo:${RESET}"
echo "  Portal:   Backstage → Create → 'Onboard a new service'"
echo "  Scripted: ./demo/onboard-service.sh checkout storefront"
echo ""
