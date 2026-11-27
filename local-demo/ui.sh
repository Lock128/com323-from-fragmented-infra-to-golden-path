#!/usr/bin/env bash
# Opens the demo UIs and the dashboard (with the live cluster view).
#   ./ui.sh   ArgoCD + Gitea + Backstage + Crossview + dashboard (live view)
# Safe to run multiple times — kills stale port-forwards/proxies on those ports first.
# DEMO_NO_OPEN=1 skips opening browser tabs. To switch between the local kind
# cluster, EKS and managed EKS, use ./target.sh (see README).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/instance.env"  # per-instance name + ports
source "${HERE}/lib-target.sh"  # records the background PIDs for ./target.sh stop
# "local" when this is the kind instance; another KUBE_CONTEXT drives the scripts
# against a different cluster (see instance.env), with the original port block.
if [[ -n "${DEMO_KUBECONFIG:-}" ]]; then DEMO_TARGET=local; else DEMO_TARGET=custom; fi
target_track_reset "local-${DEMO_NAME}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

kill_port() {
  lsof -ti tcp:"$1" -sTCP:LISTEN | xargs kill -9 2>/dev/null || true
}

wait_http() {
  local url=$1 tries=0
  while ! curl -s -o /dev/null -w "" "${url}" 2>/dev/null; do
    (( tries++ )) || true
    [[ "${tries}" -gt 20 ]] && return 1
    sleep 0.5
  done
}

echo -e "${BOLD}re:Invent 2026 (COM323) — UI Launcher${RESET}"
echo "─────────────────────────────────────────────"

kubectl config use-context ${KUBE_CONTEXT} 2>/dev/null || true

# ── ArgoCD ──────────────────────────────────────────────────────────────────
info "Starting ArgoCD port-forward on :${ARGOCD_PORT}..."
kill_port ${ARGOCD_PORT}
kubectl port-forward -n argocd svc/argocd-server ${ARGOCD_PORT}:80 \
  >/dev/null 2>&1 &
target_track $!
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "unknown")

wait_http http://localhost:${ARGOCD_PORT} && \
  success "ArgoCD:    http://localhost:${ARGOCD_PORT}  (admin / ${ARGOCD_PASSWORD})" || \
  warn    "ArgoCD:    http://localhost:${ARGOCD_PORT}  — port-forward started, may take a moment"

# ── Gitea ────────────────────────────────────────────────────────────────────
info "Starting Gitea port-forward on :${GITEA_PORT}..."
kill_port ${GITEA_PORT}
kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 \
  >/dev/null 2>&1 &
target_track $!

GITEA_PASSWORD=$(kubectl get secret -n gitea gitea-credential \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "unknown")

wait_http http://localhost:${GITEA_PORT} && \
  success "Gitea:     http://localhost:${GITEA_PORT}   (giteaAdmin / ${GITEA_PASSWORD})" || \
  warn    "Gitea:     http://localhost:${GITEA_PORT}   — port-forward started, may take a moment"

# ── Backstage ────────────────────────────────────────────────────────────────
if kubectl get svc backstage -n backstage >/dev/null 2>&1; then
  info "Starting Backstage port-forward on :${BACKSTAGE_PORT}..."
  kill_port ${BACKSTAGE_PORT}
  kubectl port-forward -n backstage svc/backstage ${BACKSTAGE_PORT}:7007 \
    >/dev/null 2>&1 &
  target_track $!

  wait_http http://localhost:${BACKSTAGE_PORT} && \
    success "Backstage: http://localhost:${BACKSTAGE_PORT}   (developer self-service portal)" || \
    warn    "Backstage: http://localhost:${BACKSTAGE_PORT}   — port-forward started, may take a moment"

  # Dex OIDC provider — must be on localhost:${DEX_PORT} so the browser can reach it
  # (the backstage pod reaches it via the dex-proxy socat sidecar). The issuer
  # URL is baked into install.yaml (dex config + backstage metadataUrl) so this
  # port MUST match packages/5-backstage/install.yaml.
  if kubectl get svc dex -n backstage >/dev/null 2>&1; then
    info "Starting Dex OIDC port-forward on :${DEX_PORT}..."
    kill_port ${DEX_PORT}
    kubectl port-forward -n backstage svc/dex ${DEX_PORT}:5656 \
      >/dev/null 2>&1 &
    target_track $!
    success "Dex OIDC:  http://localhost:${DEX_PORT}   (Backstage login — demo@example.com / password)"
  fi
else
  warn "Backstage not installed — skipping (install with: idpbuilder create --package ...)"
fi

# ── Crossview ────────────────────────────────────────────────────────────────
if kubectl get svc crossview-service -n crossview-system >/dev/null 2>&1; then
  info "Starting Crossview port-forward on :${CROSSVIEW_PORT}..."
  kill_port ${CROSSVIEW_PORT}
  kubectl port-forward -n crossview-system svc/crossview-service ${CROSSVIEW_PORT}:80 \
    >/dev/null 2>&1 &
  target_track $!

  wait_http http://localhost:${CROSSVIEW_PORT} && \
    success "Crossview: http://localhost:${CROSSVIEW_PORT}   (no login — Crossplane resource browser)" || \
    warn    "Crossview: http://localhost:${CROSSVIEW_PORT}   — port-forward started, may take a moment"
else
  warn "Crossview not installed (crossview-system/crossview-service not found)"
  echo "  Install with: run ./start.sh or re-run install_crossview from start.sh"
fi

# ── Dashboard + live cluster view ────────────────────────────────────────────
# kubectl proxy serves the dashboard AND the Kubernetes API from one origin, so the
# page can read the cluster without a custom server or CORS. Localhost only; the
# page only issues GETs.
# The pages keep the original port numbers in the repo (they are shared with
# eks-infrastructure/). Serve a copy with THIS instance's ports instead.
WWW="${TMPDIR:-/tmp}/${DEMO_NAME}-www"
rm -rf "${WWW}" && mkdir -p "${WWW}"
for f in "${HERE}"/*.html "${HERE}"/*.css "${HERE}"/*.js; do
  demo_rewrite_ports < "$f" > "${WWW}/$(basename "$f")"
done
# Target table for the cluster picker in the page header (target.js).
"${HERE}/target.sh" json > "${WWW}/targets.json" 2>/dev/null || echo '[]' > "${WWW}/targets.json"
DASH_URL="http://localhost:${DASH_PORT}/ui/dashboard.html"
info "Starting dashboard + live cluster view on :${DASH_PORT}..."
kill_port ${DASH_PORT}
kubectl proxy --port=${DASH_PORT} --www="${WWW}" --www-prefix=/ui/ \
  --accept-hosts='^localhost$,^127\.0\.0\.1$' >/dev/null 2>&1 &
target_track $!
wait_http "${DASH_URL}" && \
  success "Dashboard: ${DASH_URL}   (live: declared services → produced resources)
     Live view only: http://localhost:${DASH_PORT}/ui/show.html
     Demo steps only: http://localhost:${DASH_PORT}/ui/demo-flow.html" || \
  warn    "Dashboard: ${DASH_URL}   — proxy started, may take a moment"

# ── Dashboard action backend (localhost-only) ────────────────────────────────
# Lets the dashboard TRIGGER demo steps (change-tier, add-finops, onboard, reset)
# and run read-only kubectl from the browser. Binds to 127.0.0.1 only and runs an
# allowlisted set of our own scripts — see dashboard-server.py for the security
# notes. Harmless if it fails (the read-only dashboard still works without it).
if command -v python3 >/dev/null 2>&1 && [[ -f "${HERE}/dashboard-server.py" ]]; then
  info "Starting dashboard action backend on :${CTL_PORT} (localhost only)..."
  kill_port ${CTL_PORT}
  PORT=${CTL_PORT} DEMO_TARGET=${DEMO_TARGET} python3 "${HERE}/dashboard-server.py" >/tmp/dashboard-server-${DEMO_NAME}.log 2>&1 &
  target_track $!
  wait_http "http://localhost:${CTL_PORT}/health" && \
    success "Action backend: http://localhost:${CTL_PORT}  (trigger steps from the dashboard)" || \
    warn    "Action backend did not start — dashboard buttons will be read-only. See /tmp/dashboard-server-${DEMO_NAME}.log"
fi

if [[ "${DEMO_NO_OPEN:-}" != "1" ]]; then
  echo ""
  echo -e "${BOLD}Opening browsers...${RESET}"
  # macOS open; silently skip on Linux
  open "${DASH_URL}" 2>/dev/null || true
  open "http://localhost:${DASH_PORT}/ui/show.html" 2>/dev/null || true
  open "http://localhost:${DASH_PORT}/ui/demo-flow.html" 2>/dev/null || true
  open http://localhost:${ARGOCD_PORT} 2>/dev/null || true
  open http://localhost:${GITEA_PORT}  2>/dev/null || true
  kubectl get svc backstage -n backstage >/dev/null 2>&1 && open http://localhost:${BACKSTAGE_PORT} 2>/dev/null || true
  open http://localhost:${CROSSVIEW_PORT}  2>/dev/null || true
fi

echo ""
echo -e "${BOLD}Port-forwards + proxy are running in the background.${RESET}"
echo "  Dashboard: ${DASH_URL}"
echo "  kubectl in a shell: export KUBECONFIG=${KUBECONFIG:-~/.kube/config}"
echo "  Stop just this instance's forwards (leaves other demo instances alone):  ./target.sh stop local"
echo ""
