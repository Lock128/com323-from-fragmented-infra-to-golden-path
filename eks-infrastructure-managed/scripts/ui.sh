#!/usr/bin/env bash
# Port-forwards Backstage (:7108) and Dex (:5657) for the managed cluster, prints
# the managed Argo CD URL and, if ../local-demo is next to this app, serves the
# live dashboard (read-only) on :8021 with its action backend on :8022.
#
# The ports differ from the self-hosted variant's ui.sh (7107/5656/8011/8012), and
# this script uses its own kubeconfig file instead of switching your current
# kubectl context, so both can be open at the same time. To switch between
# local / EKS / managed, use ../local-demo/target.sh.
#
# The forwards run in the background. Stop them with:
#   ../local-demo/target.sh stop managed
#
# Defaults come from cdk.json (context.managedIdp). Overrides:
#   CLUSTER_NAME, MANAGED_IDP_REGION, AWS_PROFILE,
#   MASTERS_ROLE_ARN (optional --role-arn for kubeconfig),
#   KUBECONFIG_FILE (~/.kube/<cluster>),
#   MANAGED_DASH_PORT (8021), MANAGED_CTL_PORT (8022), DEMO_NO_OPEN=1
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
CLUSTER_NAME="${CLUSTER_NAME:-$(cfg clusterName lockheadcloud-managed)}"
REGION="${MANAGED_IDP_REGION:-$(cfg region us-west-2)}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/$CLUSTER_NAME}"
DASH_PORT_M="${MANAGED_DASH_PORT:-8021}"
CTL_PORT_M="${MANAGED_CTL_PORT:-8022}"
LOCAL_DEMO="$(cd "${APP_DIR}/../local-demo" 2>/dev/null && pwd || true)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
kill_port() { lsof -ti tcp:"$1" -sTCP:LISTEN | xargs kill -9 2>/dev/null || true; }
wait_http() {
  local url=$1 tries=0
  while ! curl -s -o /dev/null "${url}" 2>/dev/null; do
    (( tries++ )) || true; [[ "${tries}" -gt 30 ]] && return 1; sleep 0.5
  done
}
if [[ -n "${LOCAL_DEMO}" && -f "${LOCAL_DEMO}/lib-target.sh" ]]; then
  # shellcheck source=../../local-demo/lib-target.sh
  source "${LOCAL_DEMO}/lib-target.sh"
  target_track_reset managed
else
  target_track() { :; }
fi

# ── kubeconfig: own file. Keep the AWS profile already written into it ──────
if [[ -z "${AWS_PROFILE:-}" && -s "${KUBECONFIG_FILE}" ]]; then
  AWS_PROFILE="$(kubectl --kubeconfig "${KUBECONFIG_FILE}" config view --minify \
    -o jsonpath='{.users[0].user.exec.env[?(@.name=="AWS_PROFILE")].value}' 2>/dev/null || true)"
fi
export AWS_PROFILE="${AWS_PROFILE:-$DEFAULT_PROFILE}"
kubeconfig_args=(--name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG_FILE")
[[ -n "${MASTERS_ROLE_ARN:-}" ]] && kubeconfig_args+=(--role-arn "$MASTERS_ROLE_ARN")
aws eks update-kubeconfig "${kubeconfig_args[@]}" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"
KUBE_CONTEXT="$(kubectl config current-context)"
export KUBE_CONTEXT
info "Using kubeconfig ${KUBECONFIG}, context ${KUBE_CONTEXT}"

argo_url=$(aws eks describe-capability --cluster-name "$CLUSTER_NAME" --capability-name argocd \
  --region "$REGION" --query 'capability.configuration.argoCd.serverUrl' --output text 2>/dev/null || true)

kill_port 7108
kubectl port-forward -n backstage svc/backstage 7108:7007 >/dev/null 2>&1 &
target_track $!
kill_port 5657
kubectl port-forward -n backstage svc/dex 5657:5656 >/dev/null 2>&1 &
target_track $!

# ── Dashboard (read-only) — the local-demo pages, served for this cluster ────
# The managed variant has no Gitea, Crossplane or in-cluster Argo CD, so the demo
# scripts that change things are disabled here. The live view, the kubectl box and
# the read-only inspect steps work, because kro produces the same Service API,
# Argo CD Applications and registration CRDs.
DASH_URL=""
if [[ -n "${LOCAL_DEMO}" && -f "${LOCAL_DEMO}/dashboard.html" ]]; then
  WWW="$(mktemp -d "${TMPDIR:-/tmp}/managed-idp-ui.XXXXXX")"
  # Rewrite the pages' original ports to this target's ports (see local-demo/instance.env).
  (
    export DASH_PORT="${DASH_PORT_M}" CTL_PORT="${CTL_PORT_M}" BACKSTAGE_PORT=7108 DEX_PORT=5657
    # shellcheck source=../../local-demo/instance.env
    source "${LOCAL_DEMO}/instance.env"
    for f in dashboard.html show.html demo-flow.html live.js target.js demo-ui.css; do
      demo_rewrite_ports < "${LOCAL_DEMO}/${f}" > "${WWW}/${f}"
    done
  )
  if [[ -f "${APP_DIR}/../eks-infrastructure/scripts/theme-eks.css" ]]; then
    cat "${APP_DIR}/../eks-infrastructure/scripts/theme-eks.css" >> "${WWW}/demo-ui.css"
  fi
  "${LOCAL_DEMO}/target.sh" json > "${WWW}/targets.json" 2>/dev/null || echo '[]' > "${WWW}/targets.json"
  sed -i.bak "s#local-demo/ · cluster: [^ ]* · start: ./start.sh · UIs: ./ui.sh · health: ./check_health.sh#eks-infrastructure-managed/ · cluster: ${KUBE_CONTEXT} · UIs: ./scripts/ui.sh#" "${WWW}/dashboard.html"
  rm -f "${WWW}/dashboard.html.bak"

  DASH_URL="http://localhost:${DASH_PORT_M}/ui/dashboard.html"
  kill_port "${DASH_PORT_M}"
  kubectl proxy --port="${DASH_PORT_M}" --www="${WWW}" --www-prefix=/ui/ \
    --accept-hosts='^localhost$,^127\.0\.0\.1$' >/dev/null 2>&1 &
  target_track $!

  if command -v python3 >/dev/null 2>&1; then
    kill_port "${CTL_PORT_M}"
    PORT="${CTL_PORT_M}" DEMO_TARGET=managed \
      DASH_DISABLED_ACTIONS="onboard-service,onboard-existing,build-app,change-tier,show-repo,show-drift,reset-service,reset-all,add-finops,add-observability,refresh-argo" \
      DASH_DISABLED_REASON="The managed variant has no Gitea or Crossplane. Onboard through Backstage (http://localhost:7108) or kubectl apply -f examples/service.yaml." \
      python3 "${LOCAL_DEMO}/dashboard-server.py" >/tmp/dashboard-server-managed.log 2>&1 &
    target_track $!
  fi
  wait_http "${DASH_URL}" || warn "Dashboard proxy is still starting."
fi

cat <<INFO

Backstage   http://localhost:7108        demo@example.com / password
Argo CD     ${argo_url:-<capability not found>}   (IAM Identity Center sign-in)
Dashboard   ${DASH_URL:-<needs ../local-demo>}   (read-only on this variant)
kubectl     export KUBECONFIG=$KUBECONFIG_FILE

Running in the background. Stop with: ../local-demo/target.sh stop managed
INFO

if [[ "${DEMO_NO_OPEN:-}" != "1" ]]; then
  open http://localhost:7108 2>/dev/null || true
  if [[ -n "${DASH_URL}" ]]; then open "${DASH_URL}" 2>/dev/null || true; fi
fi
