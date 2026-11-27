#!/usr/bin/env bash
# ui.sh (cloud / EKS) — opens the demo UIs + the live dashboard against the
# EKS Auto Mode cluster provisioned by this CDK app. The cloud counterpart of
# local-demo/ui.sh: it starts kubectl port-forwards (so the browser-facing
# localhost URLs baked into Backstage/Dex work) and serves dashboard.html via
# `kubectl proxy` (so the page can read the cluster same-origin).
#
# The pages (dashboard, live view, demo flow) and the demo scripts are the ones in
# ../../local-demo, so there is one copy. This script serves them with the re:Invent
# palette (theme-eks.css) and starts local-demo/dashboard-server.py against THIS
# cluster (KUBE_CONTEXT), so the "Run the demo" buttons work on EKS too.
#
# kubeconfig: its own file, ~/.kube/<cluster> (see kubeconfig.sh). Your current
# context in ~/.kube/config is not changed. To switch between local / EKS /
# managed, use ../../local-demo/target.sh.
#
# Env: CLUSTER_NAME, AWS_REGION, IDP_AWS_PROFILE, MASTERS_ROLE_ARN, EKS_KUBECONFIG,
#      DEMO_NO_OPEN=1 (do not open browser tabs)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kubeconfig.sh
source "${HERE}/kubeconfig.sh"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

# Listeners only: without -sTCP:LISTEN, lsof also returns clients connected to the
# port (e.g. the browser tab showing the dashboard), which would then be killed.
kill_port() { lsof -ti tcp:"$1" -sTCP:LISTEN | xargs kill -9 2>/dev/null || true; }
wait_http() {
  local url=$1 tries=0
  while ! curl -s -o /dev/null "${url}" 2>/dev/null; do
    (( tries++ )) || true; [[ "${tries}" -gt 30 ]] && return 1; sleep 0.5
  done
}
LOCAL_DEMO="$(cd "${HERE}/../../local-demo" && pwd)"
# Background processes are recorded so `local-demo/target.sh stop eks` stops exactly these.
# shellcheck source=../../local-demo/lib-target.sh
source "${LOCAL_DEMO}/lib-target.sh"
target_track_reset eks

echo -e "${BOLD}re:Invent 2026 (COM323) — EKS UI Launcher${RESET}"
echo "─────────────────────────────────────────────"

# ── kubeconfig: own file, never the global current context ───────────────────
eks_use_kubeconfig
if ! kubectl get ns argocd >/dev/null 2>&1; then
  info "Refreshing ${EKS_KUBECONFIG} for ${CLUSTER_NAME} (${AWS_REGION})..."
  eks_write_kubeconfig || warn "update-kubeconfig failed — check your AWS credentials, then re-run."
fi
# The local-demo scripts read $KUBE_CONTEXT. Pin it to the EKS context so they can
# never fall back to the local cluster.
KUBE_CONTEXT="$(kubectl config current-context)"
export KUBE_CONTEXT
info "Using kubeconfig ${KUBECONFIG}, context ${KUBE_CONTEXT}"

# ── ArgoCD ────────────────────────────────────────────────────────────────
info "ArgoCD port-forward on :18180..."
kill_port 18180
kubectl port-forward -n argocd svc/argocd-server 18180:80 >/dev/null 2>&1 &
target_track $!
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "unknown")
wait_http http://localhost:18180 \
  && success "ArgoCD:    http://localhost:18180  (admin / ${ARGOCD_PASSWORD})" \
  || warn    "ArgoCD:    http://localhost:18180  — starting, give it a moment"

# ── Gitea ──────────────────────────────────────────────────────────────────
info "Gitea port-forward on :3100..."
kill_port 3100
kubectl port-forward -n gitea svc/my-gitea-http 3100:3000 >/dev/null 2>&1 &
target_track $!
GITEA_PASSWORD=$(kubectl -n gitea get secret gitea-credential \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "unknown")
wait_http http://localhost:3100 \
  && success "Gitea:     http://localhost:3100   (giteaAdmin / ${GITEA_PASSWORD})" \
  || warn    "Gitea:     http://localhost:3100   — starting, give it a moment"

# ── Backstage + Dex ──────────────────────────────────────────────────────
if kubectl get svc backstage -n backstage >/dev/null 2>&1; then
  info "Backstage port-forward on :7107..."
  kill_port 7107
  kubectl port-forward -n backstage svc/backstage 7107:7007 >/dev/null 2>&1 &
  target_track $!
  wait_http http://localhost:7107 \
    && success "Backstage: http://localhost:7107   (demo@example.com / password)" \
    || warn    "Backstage: http://localhost:7107   — starting, give it a moment"
  info "Dex OIDC port-forward on :5656..."
  kill_port 5656
  kubectl port-forward -n backstage svc/dex 5656:5656 >/dev/null 2>&1 &
  target_track $!
  success "Dex OIDC:  http://localhost:5656"
fi

# ── Crossview ──────────────────────────────────────────────────────────────
if kubectl get svc -n crossview-system >/dev/null 2>&1; then
  CV_SVC=$(kubectl -n crossview-system get svc -o name 2>/dev/null | grep -i crossview | head -1)
  if [[ -n "${CV_SVC}" ]]; then
    info "Crossview port-forward on :9190..."
    kill_port 9190
    kubectl port-forward -n crossview-system "${CV_SVC}" 9190:80 >/dev/null 2>&1 &
    target_track $!
    wait_http http://localhost:9190 \
      && success "Crossview: http://localhost:9190   (no login)" \
      || warn    "Crossview: http://localhost:9190   — starting, give it a moment"
  fi
fi

# ── Pages: local-demo's pages + the re:Invent palette ─────────────────────
# Rebuilt on every run into a temp dir, so the local-demo files are never modified.
WWW="$(mktemp -d "${TMPDIR:-/tmp}/idp-eks-ui.XXXXXX")"
for f in dashboard.html show.html demo-flow.html live.js target.js demo-ui.css; do
  cp "${LOCAL_DEMO}/${f}" "${WWW}/${f}"
done
cat "${HERE}/theme-eks.css" >> "${WWW}/demo-ui.css"
"${LOCAL_DEMO}/target.sh" json > "${WWW}/targets.json" || echo '[]' > "${WWW}/targets.json"
sed -i.bak "s#local-demo/ · cluster: kind-lockheadcloud · start: ./start.sh · UIs: ./ui.sh · health: ./check_health.sh#eks-infrastructure/ · cluster: ${KUBE_CONTEXT} · UIs: ./scripts/ui.sh#" "${WWW}/dashboard.html"
rm -f "${WWW}/dashboard.html.bak"

# ── Dashboard + live view (kubectl proxy serves page + EKS API same-origin) ─
DASH_URL="http://localhost:8011/ui/dashboard.html"
SHOW_URL="http://localhost:8011/ui/show.html"
FLOW_URL="http://localhost:8011/ui/demo-flow.html"
info "Dashboard + live cluster view on :8011..."
kill_port 8011
kubectl proxy --port=8011 --www="${WWW}" --www-prefix=/ui/ \
  --accept-hosts='^localhost$,^127\.0\.0\.1$' >/dev/null 2>&1 &
target_track $!
wait_http "${DASH_URL}" \
  && success "Dashboard: ${DASH_URL}
     Live view only: ${SHOW_URL}
     Demo steps only: ${FLOW_URL}" \
  || warn    "Dashboard: ${DASH_URL}  — proxy starting, give it a moment"

# ── Example repo for "onboard an existing service" (idempotent) ─────────────
if [[ -x "${LOCAL_DEMO}/seed-example-repos.sh" ]]; then
  info "Seeding the example repos (legacy-orders) into Gitea..."
  "${LOCAL_DEMO}/seed-example-repos.sh" >/tmp/seed-example-repos.log 2>&1 \
    && success "Example repos seeded" \
    || warn    "Seeding failed — onboard-existing seeds on demand. See /tmp/seed-example-repos.log"
fi

# ── Action backend (localhost only): runs the local-demo scripts against EKS ─
# DEMO_REGISTRY=ecr makes build-app.sh and add-observability.sh use private Amazon ECR
# (in the current AWS account and AWS_REGION) instead of the kind cluster's Gitea
# registry. They need working AWS credentials in this shell (AWS_PROFILE, SSO login),
# docker, and for the Go function also go and the crossplane CLI (installed on demand).
if command -v python3 >/dev/null 2>&1; then
  info "Action backend on :8012 (localhost only)..."
  kill_port 8012
  export AWS_REGION
  # kubectl reaches EKS through an exec plugin whose AWS_PROFILE lives in the kubeconfig, not in
  # this shell. The action backend inherits the shell, so without this the AWS CLI falls back to
  # the default profile (often expired) and the ECR steps fail with InvalidClientTokenId.
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    AWS_PROFILE="$(kubectl config view --minify -o jsonpath='{.users[0].user.exec.env[?(@.name=="AWS_PROFILE")].value}' 2>/dev/null || true)"
    AWS_PROFILE="${AWS_PROFILE:-${IDP_AWS_PROFILE:-default}}"
  fi
  export AWS_PROFILE
  info "AWS profile for the image steps: ${AWS_PROFILE} (${AWS_REGION})"
  PORT=8012 KUBE_CONTEXT="${KUBE_CONTEXT}" DEMO_REGISTRY=ecr DEMO_TARGET=eks \
    python3 "${LOCAL_DEMO}/dashboard-server.py" >/tmp/dashboard-server.log 2>&1 &
  target_track $!
  wait_http "http://localhost:8012/health" \
    && success "Action backend: http://localhost:8012  (run the demo from the pages)" \
    || warn    "Action backend did not start — the buttons stay disabled. See /tmp/dashboard-server.log"
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    warn "AWS profile ${AWS_PROFILE} has no valid credentials: the image build and the Go function steps push to ECR and will fail until you sign in (aws sso login --profile ${AWS_PROFILE}), then re-run this script."
  fi
fi

if [[ "${DEMO_NO_OPEN:-}" != "1" ]]; then
  echo ""
  echo -e "${BOLD}Opening browser...${RESET}"
  open "${DASH_URL}" 2>/dev/null || true
  open "${SHOW_URL}" 2>/dev/null || true
  open "${FLOW_URL}" 2>/dev/null || true
fi
echo ""
echo -e "${BOLD}Port-forwards + proxy running in the background.${RESET}"
echo "  Onboard a service:  ./scripts/apply.sh checkout storefront"
echo "  kubectl in a shell: export KUBECONFIG=${KUBECONFIG}"
echo "  Stop this target:   ../local-demo/target.sh stop eks"
echo ""
