#!/usr/bin/env bash
# target.sh — see and switch which cluster the demo runs against.
#
#   ./target.sh status                      kubeconfig, cluster and UI state of every target
#   ./target.sh start <target> [--no-open]  start that target's UIs (forwards, dashboard, backend)
#   ./target.sh stop  <target|all> [--force]
#                                           stop the UIs started for that target. --force also
#                                           stops kubectl/dashboard listeners on its ports that
#                                           were not started by this repo's scripts
#   ./target.sh env   <target>              print the exports for your own shell:
#                                             eval "$(./target.sh env eks)"
#   ./target.sh kubeconfig <target|all>     (re)write the target's own kubeconfig file
#   ./target.sh reset [--yes] [--force]     stop all UIs, rewrite every kubeconfig file, and
#                                           remove the demo EKS contexts that older scripts
#                                           wrote into ~/.kube/config (backed up first)
#   ./target.sh json                        target table for the pages' cluster picker
#
# Targets — each has its OWN kubeconfig file and its OWN ports, so all three can
# run at once and none of them changes the current context of ~/.kube/config:
#
#   local    kind cluster from ./start.sh          ~/.kube/kind-<DEMO_NAME>.yaml  dashboard :8111
#   eks      ../eks-infrastructure (self-managed)  ~/.kube/lockheadcloud-idp      dashboard :8011
#   managed  ../eks-infrastructure-managed         ~/.kube/lockheadcloud-managed  dashboard :8021
#
# The local ports come from instance.env. ~/.kube/config keeps the kind-<DEMO_NAME>
# context, because idpbuilder only writes there (start.sh copies it out).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
EKS_DIR="${REPO}/eks-infrastructure"
MANAGED_DIR="${REPO}/eks-infrastructure-managed"
# shellcheck source=lib-target.sh
source "${HERE}/lib-target.sh"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then BOLD=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; RESET=''; fi
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

TARGETS="local eks managed"
CALLER_KUBECONFIG="${KUBECONFIG:-}"
CALLER_KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# Run a command without the per-target settings this shell may carry (e.g. when the
# local dashboard backend starts the EKS UIs). Without this, instance.env and the
# ui.sh scripts would pick up the other target's kubeconfig and ports.
# The port variables are only dropped inside a demo process (DEMO_TARGET is set by
# the ui.sh scripts); from your own shell, overrides like DASH_PORT=… still apply.
CLEAN_ENV_ARGS=(-u KUBECONFIG -u KUBE_CONTEXT -u DEMO_KUBECONFIG -u PORT -u DASH_DISABLED_ACTIONS
  -u DASH_DISABLED_REASON -u DEMO_REGISTRY -u DEMO_TARGET -u CLUSTER_NAME
  -u EKS_KUBECONFIG -u KUBECONFIG_FILE -u TARGET_PIDFILE)
if [[ -n "${DEMO_TARGET:-}" ]]; then
  CLEAN_ENV_ARGS+=(-u IDP_PORT -u GITEA_HOST_PORT -u ARGOCD_PORT -u GITEA_PORT -u BACKSTAGE_PORT
    -u DEX_PORT -u CROSSVIEW_PORT -u DASH_PORT -u CTL_PORT -u APP_PORT)
fi
clean_env() { env "${CLEAN_ENV_ARGS[@]}" "$@"; }

cdk_value() {  # cdk_value <cdk.json> <js path> <default>
  local v
  v="$(node -p "try { require('$1').context.$2 ?? '' } catch (e) { '' }" 2>/dev/null || true)"
  echo "${v:-$3}"
}

# ── target table ─────────────────────────────────────────────────────────────
LOCAL_INFO="$(clean_env bash -c 'source "$1" >/dev/null 2>&1; echo "$DEMO_NAME|$DASH_PORT|$CTL_PORT|$KUBE_CONTEXT|$DEMO_KUBECONFIG"' _ "${HERE}/instance.env")"
IFS='|' read -r DEMO_NAME_L LOCAL_DASH LOCAL_CTL LOCAL_CTX LOCAL_KC <<<"${LOCAL_INFO}"
EKS_CLUSTER="$(cdk_value "${EKS_DIR}/cdk.json" idp.clusterName lockheadcloud-idp)"
MANAGED_CLUSTER="$(cdk_value "${MANAGED_DIR}/cdk.json" managedIdp.clusterName lockheadcloud-managed)"
MANAGED_REGION="${MANAGED_IDP_REGION:-$(cdk_value "${MANAGED_DIR}/cdk.json" managedIdp.region us-west-2)}"
EKS_REGION="${AWS_REGION:-us-west-2}"

# t_<field> <target>
t_label() { case "$1" in
  local)   echo "Local kind (${LOCAL_CTX})" ;;
  eks)     echo "EKS self-managed (${EKS_CLUSTER})" ;;
  managed) echo "EKS managed (${MANAGED_CLUSTER})" ;; esac; }
t_dash() { case "$1" in local) echo "${LOCAL_DASH}" ;; eks) echo 8011 ;; managed) echo "${MANAGED_DASH_PORT:-8021}" ;; esac; }
t_ctl()  { case "$1" in local) echo "${LOCAL_CTL}"  ;; eks) echo 8012 ;; managed) echo "${MANAGED_CTL_PORT:-8022}" ;; esac; }
t_kubeconfig() { case "$1" in
  local)   echo "${LOCAL_KC}" ;;
  eks)     echo "${EKS_KUBECONFIG:-${HOME}/.kube/${EKS_CLUSTER}}" ;;
  managed) echo "${HOME}/.kube/${MANAGED_CLUSTER}" ;; esac; }
t_cluster() { case "$1" in local) echo "${DEMO_NAME_L}" ;; eks) echo "${EKS_CLUSTER}" ;; managed) echo "${MANAGED_CLUSTER}" ;; esac; }
t_pidname() { case "$1" in local) echo "local-${DEMO_NAME_L}" ;; *) echo "$1" ;; esac; }
t_ui() { case "$1" in
  local)   echo "${HERE}/ui.sh" ;;
  eks)     echo "${EKS_DIR}/scripts/ui.sh" ;;
  managed) echo "${MANAGED_DIR}/scripts/ui.sh" ;; esac; }
# All local ports a target's ui.sh listens on (for stop --force).
t_ports() { case "$1" in
  local)   clean_env bash -c 'source "$1" >/dev/null 2>&1; echo $ARGOCD_PORT $GITEA_PORT $BACKSTAGE_PORT $DEX_PORT $CROSSVIEW_PORT $DASH_PORT $CTL_PORT' _ "${HERE}/instance.env" ;;
  eks)     echo "18180 3100 7107 5656 9190 8011 8012" ;;
  managed) echo "7108 5657 $(t_dash managed) $(t_ctl managed)" ;; esac; }

valid_target() { case "$1" in local|eks|managed) return 0 ;; *) return 1 ;; esac; }
need_target() {
  [[ -n "${1:-}" ]] || die "Missing target. Use one of: ${TARGETS}"
  valid_target "$1" || die "Unknown target '$1'. Use one of: ${TARGETS}"
}

# ui_state <target> → running | other | stopped   (asks the action backend)
ui_state() {
  local body
  body="$(curl -s --max-time 2 "http://127.0.0.1:$(t_ctl "$1")/health" 2>/dev/null || true)"
  if [[ -z "${body}" ]]; then echo stopped
  elif grep -q "\"target\": \"$1\"" <<<"${body}"; then echo running
  else echo other; fi
}

kc_context() { [[ -s "$1" ]] && kubectl --kubeconfig "$1" config current-context 2>/dev/null || true; }
kc_server()  { [[ -s "$1" ]] && kubectl --kubeconfig "$1" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true; }

# ── commands ─────────────────────────────────────────────────────────────────
cmd_json() {
  local t first=1
  printf '['
  for t in ${TARGETS}; do
    [[ ${first} -eq 1 ]] || printf ','
    first=0
    local dir_ok=true
    [[ -x "$(t_ui "${t}")" ]] || dir_ok=false
    printf '{"id":"%s","label":"%s","dash":%s,"ctl":%s,"kubeconfig":"%s","available":%s}' \
      "${t}" "$(t_label "${t}")" "$(t_dash "${t}")" "$(t_ctl "${t}")" "$(t_kubeconfig "${t}")" "${dir_ok}"
  done
  printf ']\n'
}

cmd_status() {
  local t kc ctx server reach state
  echo -e "${BOLD}Demo targets${RESET}"
  for t in ${TARGETS}; do
    kc="$(t_kubeconfig "${t}")"
    echo ""
    echo -e "${BOLD}${t}${RESET}  $(t_label "${t}")"
    if [[ ! -x "$(t_ui "${t}")" ]]; then echo "  (not in this checkout)"; continue; fi
    if [[ -s "${kc}" ]]; then
      ctx="$(kc_context "${kc}")"; server="$(kc_server "${kc}")"
      echo "  kubeconfig: ${kc}"
      echo "  context:    ${ctx:-(none)}"
      echo "  server:     ${server:-(none)}"
      if kubectl --kubeconfig "${kc}" --request-timeout=6s get --raw /readyz >/dev/null 2>&1; then
        reach="${GREEN}reachable${RESET}"
      else
        reach="${YELLOW}not reachable${RESET} (cluster down, or AWS sign-in needed)"
      fi
      echo -e "  cluster:    ${reach}"
    else
      echo -e "  kubeconfig: ${kc} ${YELLOW}(missing — ./target.sh kubeconfig ${t})${RESET}"
    fi
    state="$(ui_state "${t}")"
    case "${state}" in
      running) echo -e "  UIs:        ${GREEN}running${RESET}  http://localhost:$(t_dash "${t}")/ui/dashboard.html" ;;
      other)   echo -e "  UIs:        ${YELLOW}port $(t_ctl "${t}") answers, but not as '${t}'${RESET}: a backend started before target.sh existed, or another copy of the demo. ./target.sh start ${t} replaces it." ;;
      *)       echo "  UIs:        stopped  (./target.sh start ${t})" ;;
    esac
  done
  echo ""
  echo -e "${BOLD}~/.kube/config${RESET}"
  echo "  current-context: $(env -u KUBECONFIG kubectl config current-context 2>/dev/null || echo '(none)')"
  local stale
  stale="$(global_demo_contexts)"
  if [[ -n "${stale}" ]]; then
    echo -e "  ${YELLOW}demo EKS contexts written by older scripts:${RESET}"
    sed 's/^/    /' <<<"${stale}"
    echo "  (./target.sh reset moves them out, after a backup)"
  fi
  echo ""
  echo -e "${BOLD}This shell${RESET}"
  echo "  KUBECONFIG=${CALLER_KUBECONFIG:-(unset → ~/.kube/config)}"
  [[ -n "${CALLER_KUBE_CONTEXT}" ]] && echo "  KUBE_CONTEXT=${CALLER_KUBE_CONTEXT}  (the local-demo scripts follow this; unset it for the kind cluster)"
  echo "  Point it at a target:  eval \"\$(./target.sh env <local|eks|managed>)\""
}

cmd_env() {
  need_target "${1:-}"
  local kc ctx
  kc="$(t_kubeconfig "$1")"
  [[ -s "${kc}" ]] || echo "# ${kc} does not exist yet — run: ./target.sh kubeconfig $1" >&2
  ctx="$(kc_context "${kc}")"
  echo "unset KUBE_CONTEXT"
  echo "export KUBECONFIG='${kc}'"
  echo "# $(t_label "$1")${ctx:+ → ${ctx}}" >&2
}

write_kubeconfig() {
  local t="$1" kc
  kc="$(t_kubeconfig "${t}")"
  case "${t}" in
    local)
      if clean_env bash -c 'source "$1"; demo_import_kubeconfig' _ "${HERE}/instance.env"; then
        success "local: ${kc} (copied from the ${LOCAL_CTX} context in ~/.kube/config)"
      elif [[ -s "${kc}" ]]; then
        warn "local: ${LOCAL_CTX} is not in ~/.kube/config; kept the existing ${kc}"
      else
        warn "local: no ${LOCAL_CTX} context and no ${kc} — create the cluster with ./start.sh"
        return 1
      fi ;;
    eks)
      [[ -f "${EKS_DIR}/scripts/kubeconfig.sh" ]] || { warn "eks: not in this checkout"; return 1; }
      if clean_env AWS_REGION="${EKS_REGION}" bash -c 'source "$1"; eks_write_kubeconfig' _ "${EKS_DIR}/scripts/kubeconfig.sh" 2>/dev/null; then
        success "eks: ${kc} (aws eks update-kubeconfig)"
      elif clean_env AWS_REGION="${EKS_REGION}" bash -c 'source "$1"; _eks_copy_from_default' _ "${EKS_DIR}/scripts/kubeconfig.sh"; then
        success "eks: ${kc} (copied from ~/.kube/config; AWS was not reachable)"
      elif [[ -s "${kc}" ]]; then
        warn "eks: could not refresh (AWS sign-in?); kept the existing ${kc}"
      else
        warn "eks: could not write ${kc} — is the cluster deployed and are you signed in to AWS?"
        return 1
      fi ;;
    managed)
      [[ -d "${MANAGED_DIR}" ]] || { warn "managed: not in this checkout"; return 1; }
      local args=(--name "${MANAGED_CLUSTER}" --region "${MANAGED_REGION}" --kubeconfig "${kc}") profile=""
      [[ -s "${kc}" ]] && profile="$(kubectl --kubeconfig "${kc}" config view --minify \
        -o jsonpath='{.users[0].user.exec.env[?(@.name=="AWS_PROFILE")].value}' 2>/dev/null || true)"
      profile="${profile:-${AWS_PROFILE:-}}"
      [[ -n "${profile}" ]] && args+=(--profile "${profile}")
      if aws eks update-kubeconfig "${args[@]}" >/dev/null 2>&1; then
        chmod 600 "${kc}" 2>/dev/null || true
        success "managed: ${kc} (aws eks update-kubeconfig)"
      elif [[ -s "${kc}" ]]; then
        warn "managed: could not refresh (AWS sign-in?); kept the existing ${kc}"
      else
        warn "managed: could not write ${kc} — is the cluster deployed and are you signed in to AWS?"
        return 1
      fi ;;
  esac
}

cmd_kubeconfig() {
  local which="${1:-all}" t rc=0
  if [[ "${which}" == all ]]; then
    for t in ${TARGETS}; do write_kubeconfig "${t}" || rc=1; done
    return ${rc}
  fi
  need_target "${which}"
  write_kubeconfig "${which}"
}

cmd_start() {
  need_target "${1:-}"
  local t="$1" ui
  shift
  local no_open=""
  for a in "$@"; do [[ "${a}" == "--no-open" ]] && no_open=1; done
  ui="$(t_ui "${t}")"
  [[ -x "${ui}" ]] || die "${t}: ${ui} not found."
  info "Starting the ${t} UIs ($(t_label "${t}"))..."
  # Run from the script's own folder; the eks/managed scripts print paths relative to it.
  (cd "$(dirname "${ui}")" && clean_env DEMO_NO_OPEN="${no_open:-${DEMO_NO_OPEN:-}}" "${ui}")
  echo ""
  success "${t}: http://localhost:$(t_dash "${t}")/ui/dashboard.html"
}

# Stop the processes a ui.sh recorded. Only kubectl and dashboard-server.py
# processes are touched, so a reused PID never hits an unrelated program.
stop_pids() {
  local pidfile="$1" pid cmd n=0
  [[ -f "${pidfile}" ]] || { echo 0; return; }
  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${cmd}" in
      *kubectl*|*dashboard-server.py*) kill "${pid}" 2>/dev/null && n=$((n + 1)) || true ;;
    esac
  done < "${pidfile}"
  rm -f "${pidfile}"
  echo "${n}"
}

stop_ports() {
  local p pid cmd n=0
  for p in "$@"; do
    for pid in $(lsof -ti tcp:"${p}" -sTCP:LISTEN 2>/dev/null || true); do
      cmd="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
      case "${cmd}" in
        *kubectl*|*dashboard-server.py*) kill "${pid}" 2>/dev/null && n=$((n + 1)) || true ;;
      esac
    done
  done
  echo "${n}"
}

stop_one() {
  local t="$1" force="$2" n m=0
  n="$(stop_pids "$(target_pidfile "$(t_pidname "${t}")")")"
  if [[ "${force}" == 1 ]]; then
    # shellcheck disable=SC2046
    m="$(stop_ports $(t_ports "${t}"))"
  fi
  if [[ $((n + m)) -gt 0 ]]; then success "${t}: stopped $((n + m)) process(es)"
  else echo "  ${t}: nothing recorded to stop$([[ "${force}" == 1 ]] || echo " (--force also checks its ports: $(t_ports "${t}"))")"; fi
}

cmd_stop() {
  local which="${1:-}" force=0 t
  shift || true
  for a in "$@"; do [[ "${a}" == "--force" ]] && force=1; done
  [[ "${which}" == "--force" ]] && { force=1; which=all; }
  [[ -n "${which}" ]] || die "Usage: ./target.sh stop <local|eks|managed|all> [--force]"
  if [[ "${which}" == all ]]; then
    for t in ${TARGETS}; do stop_one "${t}" "${force}"; done
  else
    need_target "${which}"
    stop_one "${which}" "${force}"
  fi
}

# Contexts for the demo EKS clusters in ~/.kube/config (left there by older scripts
# or by running the stack's UpdateKubeconfigCommand without --kubeconfig).
global_demo_contexts() {
  env -u KUBECONFIG kubectl config get-contexts -o name 2>/dev/null \
    | grep -E "^arn:aws:eks:[a-z0-9-]+:[0-9]+:cluster/(${EKS_CLUSTER}|${MANAGED_CLUSTER})\$" || true
}

cmd_reset() {
  local yes=0 force=0 a
  for a in "$@"; do case "${a}" in --yes|-y) yes=1 ;; --force) force=1 ;; esac; done

  echo -e "${BOLD}1. Stop the UIs of every target${RESET}"
  if [[ ${force} == 1 ]]; then cmd_stop all --force; else cmd_stop all; fi

  echo ""
  echo -e "${BOLD}2. Rewrite each target's own kubeconfig file${RESET}"
  cmd_kubeconfig all || true

  echo ""
  echo -e "${BOLD}3. Clean up ~/.kube/config${RESET}"
  local global="${HOME}/.kube/config" stale ctx keep="" cur moved=0
  stale="$(global_demo_contexts)"
  if [[ -z "${stale}" ]]; then
    echo "  no demo EKS contexts in ${global}"
  else
    # Only remove a context whose cluster is now available from its own file.
    while read -r ctx; do
      [[ -n "${ctx}" ]] || continue
      local own=""
      case "${ctx}" in
        */"${EKS_CLUSTER}")     own="$(t_kubeconfig eks)" ;;
        */"${MANAGED_CLUSTER}") own="$(t_kubeconfig managed)" ;;
      esac
      if [[ -n "${own}" ]] && kubectl --kubeconfig "${own}" config get-contexts "${ctx}" >/dev/null 2>&1; then
        keep="${keep}${ctx}"$'\n'
      else
        warn "  keeping ${ctx}: ${own:-its own kubeconfig} does not have it yet"
      fi
    done <<<"${stale}"
    if [[ -n "${keep}" ]]; then
      echo "  These contexts now live in their own files and will be removed from ${global}:"
      sed '/^$/d; s/^/    /' <<<"${keep}"
      if [[ ${yes} -ne 1 ]]; then
        if [[ -t 0 ]]; then
          read -r -p "  Remove them? A backup of ${global} is written first. [y/N] " a
          [[ "${a}" == y || "${a}" == Y ]] || { echo "  left unchanged"; keep=""; }
        else
          echo "  not a terminal; re-run with --yes to remove them"; keep=""
        fi
      fi
    fi
    if [[ -n "${keep}" ]]; then
      local backup
      backup="${global}.bak-$(date +%Y%m%d-%H%M%S)"
      cp -p "${global}" "${backup}"
      success "backup: ${backup}"
      cur="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null || true)"
      while read -r ctx; do
        [[ -n "${ctx}" ]] || continue
        local cl us
        cl="$(env -u KUBECONFIG kubectl config view -o jsonpath="{.contexts[?(@.name==\"${ctx}\")].context.cluster}" 2>/dev/null || true)"
        us="$(env -u KUBECONFIG kubectl config view -o jsonpath="{.contexts[?(@.name==\"${ctx}\")].context.user}" 2>/dev/null || true)"
        env -u KUBECONFIG kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
        [[ -n "${cl}" ]] && env -u KUBECONFIG kubectl config delete-cluster "${cl}" >/dev/null 2>&1 || true
        [[ -n "${us}" ]] && env -u KUBECONFIG kubectl config delete-user "${us}" >/dev/null 2>&1 || true
        moved=$((moved + 1))
        if [[ "${ctx}" == "${cur}" ]]; then
          env -u KUBECONFIG kubectl config unset current-context >/dev/null 2>&1 || true
          echo "  current-context was ${ctx}; it is now unset"
        fi
      done <<<"${keep}"
      success "removed ${moved} context(s) from ${global}"
    fi
  fi

  echo ""
  if [[ -n "${CALLER_KUBECONFIG}" || -n "${CALLER_KUBE_CONTEXT}" ]]; then
    warn "This shell still has KUBECONFIG=${CALLER_KUBECONFIG:-} ${CALLER_KUBE_CONTEXT:+KUBE_CONTEXT=${CALLER_KUBE_CONTEXT}}"
    echo "  Run: unset KUBECONFIG KUBE_CONTEXT   (or eval \"\$(./target.sh env <target>)\")"
  fi
  echo "Start a target with: ./target.sh start <local|eks|managed>"
}

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

COMMAND="${1:-status}"
shift || true
case "${COMMAND}" in
  status)          cmd_status ;;
  start)           cmd_start "$@" ;;
  stop)            cmd_stop "$@" ;;
  env)             cmd_env "$@" ;;
  kubeconfig)      cmd_kubeconfig "$@" ;;
  reset)           cmd_reset "$@" ;;
  json)            cmd_json ;;
  -h|--help|help)  usage ;;
  *)               usage; exit 1 ;;
esac
