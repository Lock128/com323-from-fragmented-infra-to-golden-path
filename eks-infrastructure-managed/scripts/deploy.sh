#!/usr/bin/env bash
# deploy.sh: deploy the managed IDP-on-EKS CDK app (EKS Capabilities + CodeCommit)
# from your PC. Same shape as ../eks-infrastructure/scripts/deploy.sh.
#
# It signs in with AWS SSO (if needed), resolves the account and your SSO role,
# checks the region (CDK bootstrap, CodeCommit, no self-hosted stack operation
# in progress), runs the CDK command, and writes a kubeconfig for the cluster.
#
# Usage:  ./scripts/deploy.sh [command]
#   deploy      (default) preflight checks, deploy all stacks, kubeconfig, print URLs
#   diff        show what would change
#   synth       synthesize the CloudFormation templates only
#   status      stack and capability status, Argo CD + repo URLs
#   kubeconfig  only write the kubeconfig (~/.kube/<cluster>)
#   destroy     full teardown, same as ./scripts/delete.sh
#
# Defaults come from cdk.json (context.managedIdp). Overrides (environment):
#   IDP_AWS_PROFILE      AWS CLI profile (default: default)
#   MANAGED_IDP_REGION   target region   (default: managedIdp.region in cdk.json)
#   ADMIN_PRINCIPAL_ARN  IAM role ARN to grant cluster-admin (default: derived from your SSO login)
#   REQUIRE_APPROVAL     CDK approval level (default: never; "broadening" prompts on IAM changes)
#   FORCE=1              skip the "self-hosted stack create/update in progress" check (DELETE_IN_PROGRESS is ignored)
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

COMMAND="${1:-deploy}"
PROFILE="${IDP_AWS_PROFILE:-$DEFAULT_PROFILE}"
REGION="${MANAGED_IDP_REGION:-$(cfg region us-west-2)}"
CLUSTER_NAME="$(cfg clusterName lockheadcloud-managed)"
GIT_PROVIDER="$(cfg gitProvider codecommit)"
REQUIRE_APPROVAL="${REQUIRE_APPROVAL:-never}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/$CLUSTER_NAME}"
STACKS=(ManagedIdpVpcStack ManagedIdpEksStack)
SELF_HOSTED_STACKS=(IdpVpcStack IdpEksStack)

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# Run from the CDK app root regardless of where the script is called from.
cd "$APP_DIR"

for tool in aws node npm; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is not installed or not on PATH."
done

export AWS_PROFILE="${PROFILE}"
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

# ─── AWS sign-in ─────────────────────────────────────────────────────────────
# Capture first: piping into `grep -q` under pipefail fails on SIGPIPE.
PROFILES="$(aws configure list-profiles 2>/dev/null || true)"
grep -qx "${PROFILE}" <<<"${PROFILES}" \
  || die "AWS profile '${PROFILE}' not found in ~/.aws/config."

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  info "Session for profile '${PROFILE}' is missing or expired, signing in via SSO..."
  aws sso login --profile "${PROFILE}"
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
export CDK_DEFAULT_ACCOUNT="${ACCOUNT_ID}"
export CDK_DEFAULT_REGION="${REGION}"

echo -e "${BOLD}Managed IDP-on-EKS: ${COMMAND}${RESET}"
echo "  profile: ${PROFILE}"
echo "  account: ${ACCOUNT_ID}"
echo "  region:  ${REGION}"
echo "  cluster: ${CLUSTER_NAME}"
echo "  caller:  ${CALLER_ARN}"
echo ""

# ─── helpers ─────────────────────────────────────────────────────────────────
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_DEPLOYED"
}

stack_output() {
  aws cloudformation describe-stacks --stack-name ManagedIdpEksStack \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text 2>/dev/null || true
}

update_kubeconfig() {
  info "Writing kubeconfig ${KUBECONFIG_FILE} (your current kubectl context is not changed)..."
  local args=(--name "${CLUSTER_NAME}" --region "${REGION}" --kubeconfig "${KUBECONFIG_FILE}")
  local masters
  masters="$(aws cloudformation describe-stacks --stack-name ManagedIdpEksStack \
    --query "Stacks[0].Outputs[?OutputKey=='UpdateKubeconfigCommand'].OutputValue | [0]" \
    --output text 2>/dev/null | sed -n 's/.*--role-arn \([^ ]*\).*/\1/p')"
  # With your own admin principal, kubectl works without assuming the masters role.
  [[ -z "${ADMIN_ARN:-}" && -n "${masters}" ]] && args+=(--role-arn "${masters}")
  aws eks update-kubeconfig "${args[@]}" >/dev/null
  success "kubectl: export KUBECONFIG=${KUBECONFIG_FILE}"
}

print_urls() {
  local argo repo
  argo="$(stack_output ArgoCdServerUrl)"
  repo="$(stack_output PlatformRepoUrl)"
  echo "  Argo CD:       ${argo:-<not deployed>}  (IAM Identity Center sign-in)"
  echo "  Platform repo: ${repo:-<not deployed>}"
}

# ─── commands that need no CDK ───────────────────────────────────────────────
case "${COMMAND}" in
  kubeconfig)
    ADMIN_ARN=""
    update_kubeconfig
    exit 0
    ;;
  status)
    for s in "${STACKS[@]}"; do printf '  %-20s %s\n' "$s" "$(stack_status "$s")"; done
    for c in argocd kro ack; do
      printf '  capability %-9s %s\n' "$c" "$(aws eks describe-capability --cluster-name "${CLUSTER_NAME}" \
        --capability-name "$c" --query capability.status --output text 2>/dev/null || echo "-")"
    done
    print_urls
    exit 0
    ;;
esac

# ─── cluster admin principal ─────────────────────────────────────────────────
# EKS access entries need the SSO role's real IAM ARN, including its
# /aws-reserved/sso.amazonaws.com/... path, so look it up instead of rebuilding
# it from the session ARN.
ADMIN_ARN="${ADMIN_PRINCIPAL_ARN:-}"
if [[ -z "${ADMIN_ARN}" && "${CALLER_ARN}" == *":assumed-role/"* ]]; then
  ROLE_NAME="${CALLER_ARN#*:assumed-role/}"
  ROLE_NAME="${ROLE_NAME%%/*}"
  ADMIN_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text 2>/dev/null || true)"
fi
if [[ -n "${ADMIN_ARN}" ]]; then
  info "kubectl cluster-admin will be granted to ${ADMIN_ARN}"
else
  warn "No admin principal derived; set ADMIN_PRINCIPAL_ARN to get kubectl access."
fi

# ─── dependencies ────────────────────────────────────────────────────────────
if [[ ! -d node_modules ]]; then
  info "Installing dependencies (npm ci)..."
  npm ci
fi

CDK=(npx cdk --toolkit-stack-name "${TOOLKIT_STACK}")
CONTEXT=(--context "managedIdp:region=${REGION}")
[[ -n "${ADMIN_ARN}" ]] && CONTEXT+=(--context "adminPrincipalArn=${ADMIN_ARN}")

# ─── preflight ───────────────────────────────────────────────────────────────
# This app has its own bootstrap stack (qualifier + stack name in cdk.json), so
# it shares no assets bucket, ECR repo or deploy roles with the self-hosted
# variant, which uses the default CDKToolkit.
ensure_bootstrapped() {
  [[ -n "${BOOTSTRAP_QUALIFIER}" && -n "${TOOLKIT_STACK}" ]] \
    || die "cdk.json must set toolkitStackName and context @aws-cdk/core:bootstrapQualifier."
  if aws ssm get-parameter --name "/cdk-bootstrap/${BOOTSTRAP_QUALIFIER}/version" >/dev/null 2>&1; then
    return
  fi
  info "Creating this app's own CDK bootstrap stack ${TOOLKIT_STACK} (qualifier ${BOOTSTRAP_QUALIFIER}) in ${REGION}..."
  "${CDK[@]}" bootstrap "aws://${ACCOUNT_ID}/${REGION}" \
    --qualifier "${BOOTSTRAP_QUALIFIER}"  # --toolkit-stack-name is already in ${CDK[@]}; passing it twice breaks bootstrap
}

# Both apps' kubectl steps run on Lambda, and the account allows only 10
# concurrent executions per region. Running alongside a self-hosted stack
# operation in the same region can fail with "Rate Exceeded".
ensure_no_parallel_operation() {
  [[ "${FORCE:-}" == 1 ]] && return
  local s st
  for s in "${SELF_HOSTED_STACKS[@]}"; do
    st="$(stack_status "$s")"
    if [[ "$st" == *_IN_PROGRESS && "$st" != DELETE_IN_PROGRESS ]]; then
      die "Self-hosted stack $s is $st in ${REGION}. Wait for it to finish (Lambda concurrency), or set FORCE=1."
    fi
  done
}

ensure_codecommit() {
  [[ "${GIT_PROVIDER}" == codecommit ]] || return 0
  aws codecommit list-repositories --max-items 1 >/dev/null 2>&1 \
    || die "CodeCommit is not usable in ${REGION} for this account. Pick another region or set managedIdp.gitProvider=external."
}

case "${COMMAND}" in
  deploy)
    ensure_no_parallel_operation
    ensure_codecommit
    ensure_bootstrapped
    info "Deploying all stacks (first run takes roughly 30-40 minutes)..."
    "${CDK[@]}" deploy --all --require-approval "${REQUIRE_APPROVAL}" "${CONTEXT[@]}"
    success "Deploy finished."
    update_kubeconfig
    echo ""
    print_urls
    echo ""
    echo -e "${BOLD}Next:${RESET}"
    echo "  ./scripts/ui.sh                     # Backstage on http://localhost:7108"
    echo "  ./scripts/codecommit-setup.sh clone # clone the platform repo (golden path, RGD, CRDs)"
    echo "  KUBECONFIG=${KUBECONFIG_FILE} kubectl get resourcegraphdefinitions"
    ;;
  diff)
    "${CDK[@]}" diff --all "${CONTEXT[@]}"
    ;;
  synth)
    "${CDK[@]}" synth --quiet "${CONTEXT[@]}"
    success "Synthesis finished."
    ;;
  destroy)
    # Full teardown (in-cluster cleanup, stacks, service repos, leftovers).
    info "Handing over to scripts/delete.sh..."
    exec "${APP_DIR}/scripts/delete.sh"
    ;;
  *)
    die "Unknown command '${COMMAND}'. Use: deploy | diff | synth | status | kubeconfig | destroy"
    ;;
esac
