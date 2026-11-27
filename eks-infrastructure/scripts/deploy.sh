#!/usr/bin/env bash
# deploy.sh — convenience wrapper to deploy the IDP-on-EKS CDK app from your PC.
#
# It signs in with AWS SSO (if needed), resolves the account, installs
# dependencies, bootstraps CDK once per account/region, runs the CDK command,
# and points kubectl at the cluster afterwards.
#
# Usage:  ./scripts/deploy.sh [command]
#   deploy      (default) bootstrap if needed, deploy all stacks, update kubeconfig
#   diff        show what would change
#   synth       synthesize the CloudFormation templates only
#   destroy     delete all stacks (CDK asks for confirmation)
#   kubeconfig  only point kubectl at the cluster
#
# Overrides (environment variables):
#   IDP_AWS_PROFILE    AWS CLI profile   (default: default)
#   AWS_REGION         target region     (default: us-west-2)
#   ADMIN_PRINCIPAL_ARN  IAM role ARN to grant cluster-admin (default: derived from your SSO login)
#   REQUIRE_APPROVAL   CDK approval level (default: never; use "broadening" to be prompted on IAM changes)
set -euo pipefail

COMMAND="${1:-deploy}"
PROFILE="${IDP_AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-west-2}"
REQUIRE_APPROVAL="${REQUIRE_APPROVAL:-never}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# Run from the CDK app root regardless of where the script is called from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  info "Session for profile '${PROFILE}' is missing or expired — signing in via SSO..."
  aws sso login --profile "${PROFILE}"
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
export CDK_DEFAULT_ACCOUNT="${ACCOUNT_ID}"
export CDK_DEFAULT_REGION="${REGION}"

echo -e "${BOLD}IDP-on-EKS — ${COMMAND}${RESET}"
echo "  profile: ${PROFILE}"
echo "  account: ${ACCOUNT_ID}"
echo "  region:  ${REGION}"
echo "  caller:  ${CALLER_ARN}"
echo ""

# ─── cluster admin principal ─────────────────────────────────────────────────
# An SSO session reports arn:aws:sts::<acct>:assumed-role/AWSReservedSSO_<set>_<id>/<user>,
# but the IAM role itself lives under a path, e.g.
#   arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<set>_<id>
# EKS access entries need the role's REAL ARN including that path (only the old
# aws-auth ConfigMap required stripping it), so look it up from IAM instead of
# rebuilding it from the session ARN.
ADMIN_ARN="${ADMIN_PRINCIPAL_ARN:-}"
if [[ -z "${ADMIN_ARN}" && "${CALLER_ARN}" == *":assumed-role/"* ]]; then
  ROLE_NAME="${CALLER_ARN#*:assumed-role/}"
  ROLE_NAME="${ROLE_NAME%%/*}"
  ADMIN_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text 2>/dev/null || true)"
fi
if [[ -n "${ADMIN_ARN}" ]]; then
  info "kubectl cluster-admin will be granted to ${ADMIN_ARN}"
else
  warn "No admin principal derived — set ADMIN_PRINCIPAL_ARN to get kubectl access."
fi

CLUSTER_NAME="$(node -p "require('./cdk.json').context.idp.clusterName" 2>/dev/null || echo lockheadcloud-idp)"

# Own kubeconfig file (~/.kube/<cluster>), so ~/.kube/config and its current
# context are not changed. See kubeconfig.sh and ../../local-demo/target.sh.
update_kubeconfig() {
  info "Writing kubeconfig for ${CLUSTER_NAME} (your current kubectl context is not changed)..."
  (
    AWS_REGION="${REGION}"; IDP_AWS_PROFILE="${PROFILE}"
    # shellcheck source=kubeconfig.sh
    source scripts/kubeconfig.sh
    eks_write_kubeconfig
  )
  success "kubectl: export KUBECONFIG=${EKS_KUBECONFIG:-${HOME}/.kube/${CLUSTER_NAME}}   (or: eval \"\$(../local-demo/target.sh env eks)\")"
}

if [[ "${COMMAND}" == "kubeconfig" ]]; then
  update_kubeconfig
  exit 0
fi

# ─── dependencies ────────────────────────────────────────────────────────────
if [[ ! -d node_modules ]]; then
  info "Installing dependencies (npm ci)..."
  npm ci
fi

CDK=(npx cdk)
CONTEXT=()
[[ -n "${ADMIN_ARN}" ]] && CONTEXT=(--context "adminPrincipalArn=${ADMIN_ARN}")

# ─── CDK bootstrap (once per account/region) ─────────────────────────────────
ensure_bootstrapped() {
  if aws ssm get-parameter --name /cdk-bootstrap/hnb659fds/version \
       --region "${REGION}" >/dev/null 2>&1; then
    return
  fi
  info "Account ${ACCOUNT_ID} / ${REGION} is not CDK-bootstrapped — bootstrapping..."
  "${CDK[@]}" bootstrap "aws://${ACCOUNT_ID}/${REGION}"
}

case "${COMMAND}" in
  deploy)
    ensure_bootstrapped
    info "Deploying all stacks (first run takes roughly 20-30 minutes)..."
    "${CDK[@]}" deploy --all --require-approval "${REQUIRE_APPROVAL}" ${CONTEXT[@]+"${CONTEXT[@]}"}
    success "Deploy finished."
    update_kubeconfig
    echo ""
    echo -e "${BOLD}Next:${RESET}"
    echo "  ./scripts/ui.sh                          # port-forwards + live dashboard"
    echo "  ./scripts/apply.sh checkout storefront   # onboard a service from the CLI"
    ;;
  diff)
    "${CDK[@]}" diff --all ${CONTEXT[@]+"${CONTEXT[@]}"}
    ;;
  synth)
    "${CDK[@]}" synth --quiet ${CONTEXT[@]+"${CONTEXT[@]}"}
    success "Synthesis finished."
    ;;
  destroy)
    warn "This deletes the EKS cluster, VPC, and all platform data (Gitea repos, Backstage DB)."
    "${CDK[@]}" destroy --all ${CONTEXT[@]+"${CONTEXT[@]}"}
    ;;
  *)
    die "Unknown command '${COMMAND}'. Use: deploy | diff | synth | destroy | kubeconfig"
    ;;
esac
