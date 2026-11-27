#!/usr/bin/env bash
# delete.sh — tear down the IDP-on-EKS environment completely.
#
# A plain `cdk destroy` is not enough on its own. The EBS volumes behind the
# Gitea and Postgres PVCs are created by Kubernetes, not CloudFormation, so if
# the cluster disappears first they can be left behind and keep costing money.
# Kubernetes-created load balancers can also block the VPC from being deleted.
# So this script cleans up inside the cluster first, then destroys the stacks,
# then checks for leftovers.
#
# Steps:
#   1. Delete onboarded Services (Crossplane cascades to Argo CD apps + registrations)
#   2. Delete LoadBalancer Services and the PVCs (so EBS volumes are released)
#   3. cdk destroy --all
#   4. Delete the cluster's CloudWatch log group (EKS leaves it behind)
#   5. Report any EBS volumes that look like leftovers (never deletes them)
#
# Usage:  ./scripts/delete.sh [--yes]
#   --yes   skip the confirmation prompt
#
# Overrides (environment variables):
#   IDP_AWS_PROFILE   AWS CLI profile (default: default)
#   AWS_REGION        target region   (default: us-west-2)
#
# Not removed: the shared CDKToolkit bootstrap stack (other CDK apps may use it).
set -euo pipefail

ASSUME_YES="false"
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES="true"

PROFILE="${IDP_AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-west-2}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in aws node npm kubectl; do
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
export CDK_DEFAULT_ACCOUNT="${ACCOUNT_ID}"
export CDK_DEFAULT_REGION="${REGION}"

CLUSTER_NAME="$(node -p "require('./cdk.json').context.idp.clusterName" 2>/dev/null || echo lockheadcloud-idp)"
CLUSTER_ARN="arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

echo -e "${BOLD}IDP-on-EKS — DELETE${RESET}"
echo "  profile: ${PROFILE}"
echo "  account: ${ACCOUNT_ID}"
echo "  region:  ${REGION}"
echo "  cluster: ${CLUSTER_NAME}"
echo ""
echo "This permanently deletes the EKS cluster, the VPC and NAT gateway, and all"
echo "platform data (Gitea repositories, Backstage database, onboarded services)."

if [[ "${ASSUME_YES}" != "true" ]]; then
  echo ""
  read -r -p "Type the cluster name (${CLUSTER_NAME}) to confirm: " ANSWER
  [[ "${ANSWER}" == "${CLUSTER_NAME}" ]] || die "Confirmation did not match — nothing was deleted."
fi

# ─── 1+2. In-cluster cleanup (best effort) ───────────────────────────────────
# Uses a throwaway kubeconfig so your own ~/.kube/config is not modified.
CLUSTER_EXISTS="false"
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  CLUSTER_EXISTS="true"
fi

cleanup_cluster() {
  local kc k
  kc="$(mktemp "${TMPDIR:-/tmp}/idp-delete-kubeconfig.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${kc}'" RETURN
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" \
    --profile "${PROFILE}" --kubeconfig "${kc}" >/dev/null
  k=(kubectl --kubeconfig "${kc}")

  if ! "${k[@]}" get ns >/dev/null 2>&1; then
    warn "Cannot reach the cluster with kubectl (no access entry for your role?)."
    return 1
  fi

  info "Deleting onboarded Service claims (Crossplane cascades)..."
  "${k[@]}" delete services.lockhead.cloud --all -A --ignore-not-found --wait --timeout=3m \
    || warn "Service deletion did not finish cleanly — continuing."

  info "Deleting LoadBalancer Services so their load balancers are removed..."
  local lbs
  lbs="$("${k[@]}" get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "${lbs}" ]]; then
    while read -r ns name; do
      [[ -n "${name}" ]] && "${k[@]}" delete svc "${name}" -n "${ns}" --wait --timeout=3m || true
    done <<<"${lbs}"
  else
    echo "  none"
  fi

  info "Deleting workloads and PVCs so EBS volumes are released..."
  local ns
  for ns in gitea backstage; do
    "${k[@]}" get ns "${ns}" >/dev/null 2>&1 || continue
    # A PVC cannot be released while a pod still mounts it.
    "${k[@]}" delete statefulset --all -n "${ns}" --ignore-not-found --wait --timeout=3m || true
    "${k[@]}" delete deployment --all -n "${ns}" --ignore-not-found --wait --timeout=3m || true
    "${k[@]}" delete pvc --all -n "${ns}" --ignore-not-found --wait --timeout=5m \
      || warn "PVCs in '${ns}' were not deleted in time — check for leftover volumes at the end."
  done
  success "In-cluster cleanup done."
}

if [[ "${CLUSTER_EXISTS}" == "true" ]]; then
  cleanup_cluster || warn "Skipping in-cluster cleanup — leftover EBS volumes are possible (checked at the end)."
else
  info "Cluster '${CLUSTER_NAME}' not found — skipping in-cluster cleanup."
fi

# ─── 3. Destroy the stacks ───────────────────────────────────────────────────
if [[ ! -d node_modules ]]; then
  info "Installing dependencies (npm ci)..."
  npm ci
fi

info "Destroying all CDK stacks (EKS first, then the VPC)..."
npx cdk destroy --all --force
success "Stacks destroyed."

# ─── 4. Log group left behind by EKS ─────────────────────────────────────────
LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"
LG_FOUND="$(aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" \
  --region "${REGION}" --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text 2>/dev/null || true)"
if [[ -n "${LG_FOUND}" ]]; then
  info "Deleting CloudWatch log group ${LOG_GROUP} (EKS does not remove it)..."
  aws logs delete-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" || true
fi

# ─── 5. Leftover check (report only, never deletes) ──────────────────────────
# Unattached EBS volumes that were created by Kubernetes PVCs. Ownership across
# clusters cannot be proven from tags alone, so these are listed, not deleted.
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
LEFTOVERS="$(aws ec2 describe-volumes --region "${REGION}" \
  --filters "Name=status,Values=available" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
  --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text 2>/dev/null || true)"
echo ""
if [[ -n "${LEFTOVERS}" ]]; then
  warn "Unattached EBS volumes created by Kubernetes PVCs exist in ${REGION}:"
  echo "${LEFTOVERS}" | awk '{printf "    %s  %sGiB  pvc=%s\n", $1, $2, $3}'
  echo "  If they belonged to this demo, delete with:  aws ec2 delete-volume --volume-id <id> --region ${REGION}"
else
  success "No leftover Kubernetes-created EBS volumes found."
fi

# ─── local kubeconfig tidy-up ────────────────────────────────────────────────
# The cluster's own file (written by deploy.sh / ui.sh), and the context older
# versions of these scripts wrote into ~/.kube/config.
OWN_KUBECONFIG="${EKS_KUBECONFIG:-${HOME}/.kube/${CLUSTER_NAME}}"
if [[ -f "${OWN_KUBECONFIG}" ]]; then
  rm -f "${OWN_KUBECONFIG}" && echo "Removed ${OWN_KUBECONFIG}"
fi
for kind in context cluster user; do
  case "${kind}" in
    context) env -u KUBECONFIG kubectl config delete-context "${CLUSTER_ARN}" >/dev/null 2>&1 && echo "Removed kubeconfig context ${CLUSTER_ARN}" || true ;;
    cluster) env -u KUBECONFIG kubectl config delete-cluster "${CLUSTER_ARN}" >/dev/null 2>&1 || true ;;
    user)    env -u KUBECONFIG kubectl config unset "users.${CLUSTER_ARN}" >/dev/null 2>&1 || true ;;
  esac
done

echo ""
success "Teardown complete. The shared CDKToolkit bootstrap stack was left in place."
