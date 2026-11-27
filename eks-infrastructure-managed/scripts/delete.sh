#!/usr/bin/env bash
# delete.sh: tear down the managed IDP-on-EKS environment completely.
# Same shape as ../eks-infrastructure/scripts/delete.sh.
#
# A plain `cdk destroy` is not enough on its own:
#  - The EBS volume behind Backstage's Postgres PVC is created by Kubernetes,
#    not CloudFormation, and can be left behind if the cluster goes first.
#  - The ECR repos per service are created by ACK. They are only deleted while
#    the cluster (and ACK) still runs and the Service is removed.
#  - The svc-* CodeCommit repos are created by the Backstage scaffold Job, not
#    CloudFormation.
#  - Argo CD self-heal would re-apply Services from Git while you delete them,
#    so the per-service Argo CD apps have to go first.
#
# Steps:
#   1. Delete the Backstage-created Argo CD apps (svc-*), then the Services
#      (kro cascades: Argo CD app, ACK ECR repo, registrations)
#   2. Delete LoadBalancer Services, then Backstage's workloads and PVCs
#   3. cdk destroy --all (also deletes the platform CodeCommit repo)
#   4. Delete the svc-* CodeCommit repos created by the portal (only those
#      carrying the lockhead.cloud/service tag that scaffold.sh sets)
#   5. Delete the cluster's CloudWatch log group (EKS leaves it behind)
#   6. Report leftover EBS volumes and ECR repos (never deletes them)
#   7. Remove the local kubeconfig for the cluster
#
# Usage:  ./scripts/delete.sh [--yes] [--dry-run] [--keep-service-repos]
#   --yes                 skip the confirmation prompt
#   --dry-run             show what would be deleted, change nothing
#   --keep-service-repos  keep the svc-* CodeCommit repos
#
# Defaults come from cdk.json (context.managedIdp). Overrides (environment):
#   IDP_AWS_PROFILE      AWS CLI profile (default: default)
#   MANAGED_IDP_REGION   target region   (default: managedIdp.region in cdk.json)
#   FORCE=1              skip the "self-hosted stack create/update in progress" check (DELETE_IN_PROGRESS is ignored)
#
# Not removed: this app's own bootstrap stack (toolkitStackName in cdk.json).
# It is cheap to keep and makes the next deploy faster; the final message shows
# how to remove it.
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

ASSUME_YES="false"; DRY_RUN="false"; KEEP_SERVICE_REPOS="false"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES="true" ;;
    --dry-run) DRY_RUN="true" ;;
    --keep-service-repos) KEEP_SERVICE_REPOS="true" ;;
    *) echo "Unknown option: $arg (use --yes | --dry-run | --keep-service-repos)" >&2; exit 1 ;;
  esac
done

PROFILE="${IDP_AWS_PROFILE:-$DEFAULT_PROFILE}"
REGION="${MANAGED_IDP_REGION:-$(cfg region us-west-2)}"
CLUSTER_NAME="$(cfg clusterName lockheadcloud-managed)"
PLATFORM_REPO="$(cfg repositoryName lockheadcloud-managed-platform)"
SERVICE_REPO_PREFIX="$(cfg serviceRepoPrefix svc-)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/$CLUSTER_NAME}"
SERVICE_TAG="lockhead.cloud/service"
SELF_HOSTED_STACKS=(IdpVpcStack IdpEksStack)

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# Mutating commands go through run(): printed instead of executed with --dry-run.
run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# Prints a "done" message only when something actually happened.
done_msg() { [[ "${DRY_RUN}" == "true" ]] || echo "$*"; }

cd "$APP_DIR"

for tool in aws node npm kubectl; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is not installed or not on PATH."
done

export AWS_PROFILE="${PROFILE}"
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

# ─── AWS sign-in ─────────────────────────────────────────────────────────────
PROFILES="$(aws configure list-profiles 2>/dev/null || true)"
grep -qx "${PROFILE}" <<<"${PROFILES}" \
  || die "AWS profile '${PROFILE}' not found in ~/.aws/config."

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  info "Session for profile '${PROFILE}' is missing or expired, signing in via SSO..."
  aws sso login --profile "${PROFILE}"
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export CDK_DEFAULT_ACCOUNT="${ACCOUNT_ID}"
export CDK_DEFAULT_REGION="${REGION}"
CLUSTER_ARN="arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

# ─── what will be deleted ────────────────────────────────────────────────────
# svc-* repos created by the portal: prefix AND the tag scaffold.sh sets, so
# unrelated repos that happen to share the prefix are never touched.
find_service_repos() {
  local names name tags
  names="$(aws codecommit list-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null || true)"
  for name in ${names}; do
    [[ "${name}" == "${SERVICE_REPO_PREFIX}"* ]] || continue
    tags="$(aws codecommit list-tags-for-resource \
      --resource-arn "arn:aws:codecommit:${REGION}:${ACCOUNT_ID}:${name}" \
      --query "tags.\"${SERVICE_TAG}\"" --output text 2>/dev/null || true)"
    [[ -n "${tags}" && "${tags}" != "None" ]] && echo "${name}"
  done
}
SERVICE_REPOS="$(find_service_repos)"

echo -e "${BOLD}Managed IDP-on-EKS: DELETE$([[ "${DRY_RUN}" == true ]] && echo " (dry run)")${RESET}"
echo "  profile: ${PROFILE}"
echo "  account: ${ACCOUNT_ID}"
echo "  region:  ${REGION}"
echo "  cluster: ${CLUSTER_NAME}"
echo ""
echo "This permanently deletes the EKS cluster with its Argo CD, kro and ACK"
echo "capabilities, the VPC and NAT gateway, Backstage's database, the onboarded"
echo "services with their ECR repos, and the platform CodeCommit repo"
echo "'${PLATFORM_REPO}', including everything you pushed to it."
if [[ "${KEEP_SERVICE_REPOS}" == "true" ]]; then
  echo "Service CodeCommit repos are kept (--keep-service-repos)."
elif [[ -n "${SERVICE_REPOS}" ]]; then
  echo "Service CodeCommit repos that will be deleted:"
  while read -r r; do [[ -n "$r" ]] && echo "    $r"; done <<<"${SERVICE_REPOS}"
else
  echo "No service CodeCommit repos (${SERVICE_REPO_PREFIX}*) found."
fi

if [[ "${ASSUME_YES}" != "true" && "${DRY_RUN}" != "true" ]]; then
  echo ""
  read -r -p "Type the cluster name (${CLUSTER_NAME}) to confirm: " ANSWER
  [[ "${ANSWER}" == "${CLUSTER_NAME}" ]] || die "Confirmation did not match; nothing was deleted."
fi
echo ""

# Both apps' kubectl steps run on Lambda (10 concurrent executions per region).
if [[ "${FORCE:-}" != 1 ]]; then
  for s in "${SELF_HOSTED_STACKS[@]}"; do
    st="$(aws cloudformation describe-stacks --stack-name "$s" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
    [[ "$st" == *_IN_PROGRESS && "$st" != DELETE_IN_PROGRESS ]] \
      && die "Self-hosted stack $s is $st in ${REGION}. Wait for it to finish (Lambda concurrency), or set FORCE=1."
  done
fi

# ─── 1+2. In-cluster cleanup (best effort) ───────────────────────────────────
CLUSTER_EXISTS="false"
if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  CLUSTER_EXISTS="true"
fi

cleanup_cluster() {
  local kc k
  # Throwaway kubeconfig, so no kubeconfig of yours is modified.
  kc="$(mktemp "${TMPDIR:-/tmp}/managed-idp-delete-kubeconfig.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${kc}'" RETURN
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${kc}" >/dev/null
  k=(kubectl --kubeconfig "${kc}")

  if ! "${k[@]}" get ns >/dev/null 2>&1; then
    warn "Cannot reach the cluster with kubectl (no access entry for your role?)."
    return 1
  fi

  info "Deleting the per-service Argo CD apps created by Backstage (stops self-heal)..."
  run "${k[@]}" delete applications.argoproj.io -n argocd \
    -l lockhead.cloud/managed-by=backstage --ignore-not-found --wait --timeout=3m \
    || warn "Argo CD app deletion did not finish cleanly; continuing."

  info "Deleting onboarded Services (kro removes their Argo CD apps, ECR repos and registrations)..."
  if "${k[@]}" get crd services.lockhead.cloud >/dev/null 2>&1; then
    run "${k[@]}" delete services.lockhead.cloud --all -A --ignore-not-found --wait --timeout=5m \
      || warn "Service deletion did not finish cleanly; continuing."
  else
    echo "  Service API not installed"
  fi

  # ACK deletes the ECR repos asynchronously; wait so the controller is still
  # running when they go (the capability disappears with the stack).
  if "${k[@]}" get crd repositories.ecr.services.k8s.aws >/dev/null 2>&1; then
    info "Waiting for ACK to delete the ECR repositories..."
    run "${k[@]}" wait --for=delete repositories.ecr.services.k8s.aws --all -A --timeout=5m \
      || warn "Some ECR repositories are still being deleted; checked at the end."
  fi

  info "Deleting LoadBalancer Services so their load balancers are removed..."
  local lbs
  lbs="$("${k[@]}" get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "${lbs}" ]]; then
    while read -r ns name; do
      [[ -n "${name}" ]] && { run "${k[@]}" delete svc "${name}" -n "${ns}" --wait --timeout=3m || true; }
    done <<<"${lbs}"
  else
    echo "  none"
  fi

  info "Deleting Backstage's workloads and PVCs so the EBS volume is released..."
  if "${k[@]}" get ns backstage >/dev/null 2>&1; then
    # A PVC cannot be released while a pod still mounts it.
    run "${k[@]}" delete statefulset --all -n backstage --ignore-not-found --wait --timeout=3m || true
    run "${k[@]}" delete deployment --all -n backstage --ignore-not-found --wait --timeout=3m || true
    run "${k[@]}" delete pvc --all -n backstage --ignore-not-found --wait --timeout=5m \
      || warn "PVCs in 'backstage' were not deleted in time; check for leftover volumes at the end."
  else
    echo "  namespace backstage not found"
  fi
  success "In-cluster cleanup done."
}

if [[ "${CLUSTER_EXISTS}" == "true" ]]; then
  cleanup_cluster || warn "Skipping in-cluster cleanup; leftover EBS volumes and ECR repos are possible (checked at the end)."
else
  info "Cluster '${CLUSTER_NAME}' not found, skipping in-cluster cleanup."
fi

# ─── 3. Destroy the stacks ───────────────────────────────────────────────────
if [[ ! -d node_modules ]]; then
  info "Installing dependencies (npm ci)..."
  run npm ci
fi

info "Destroying all CDK stacks (EKS first, then the VPC)..."
run npx cdk destroy --all --force --toolkit-stack-name "${TOOLKIT_STACK}" --context "managedIdp:region=${REGION}"
[[ "${DRY_RUN}" == "true" ]] || success "Stacks destroyed."

# ─── 4. Service CodeCommit repos ─────────────────────────────────────────────
if [[ "${KEEP_SERVICE_REPOS}" != "true" && -n "${SERVICE_REPOS}" ]]; then
  info "Deleting service CodeCommit repos..."
  while read -r r; do
    [[ -n "$r" ]] || continue
    run aws codecommit delete-repository --repository-name "$r" --query repositoryId --output text >/dev/null \
      || warn "Could not delete $r"
    [[ "${DRY_RUN}" == "true" ]] && echo "  [dry-run] delete CodeCommit repo $r" || echo "  deleted $r"
  done <<<"${SERVICE_REPOS}"
fi

# ─── 5. Log group left behind by EKS ─────────────────────────────────────────
LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"
LG_FOUND="$(aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" --output text 2>/dev/null || true)"
if [[ -n "${LG_FOUND}" ]]; then
  info "Deleting CloudWatch log group ${LOG_GROUP} (EKS does not remove it)..."
  run aws logs delete-log-group --log-group-name "${LOG_GROUP}" || true
fi

# ─── 6. Leftover check (report only, never deletes) ──────────────────────────
echo ""
# Unattached EBS volumes created by Kubernetes PVCs. Both IDP variants may run
# in this region and tags cannot prove which cluster owned a volume, so they
# are listed, not deleted.
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
LEFTOVER_VOLUMES="$(aws ec2 describe-volumes \
  --filters "Name=status,Values=available" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
  --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text 2>/dev/null || true)"
if [[ -n "${LEFTOVER_VOLUMES}" ]]; then
  warn "Unattached EBS volumes created by Kubernetes PVCs exist in ${REGION}:"
  echo "${LEFTOVER_VOLUMES}" | awk '{printf "    %s  %sGiB  pvc=%s\n", $1, $2, $3}'
  echo "  If they belonged to this demo, delete with:  aws ec2 delete-volume --volume-id <id> --region ${REGION}"
else
  success "No leftover Kubernetes-created EBS volumes found."
fi

# ECR repos the Service API creates are named <team>/<service> and tagged.
LEFTOVER_ECR=""
for repo in $(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null || true); do
  [[ "${repo}" == */* ]] || continue
  tag="$(aws ecr list-tags-for-resource \
    --resource-arn "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${repo}" \
    --query "tags[?Key=='${SERVICE_TAG}'].Value | [0]" --output text 2>/dev/null || true)"
  [[ -n "${tag}" && "${tag}" != "None" ]] && LEFTOVER_ECR+="    ${repo}"$'\n'
done
if [[ -n "${LEFTOVER_ECR}" ]]; then
  warn "ECR repositories created for onboarded services still exist:"
  printf '%s' "${LEFTOVER_ECR}"
  echo "  If they belonged to this demo, delete with:  aws ecr delete-repository --force --repository-name <name> --region ${REGION}"
else
  success "No leftover service ECR repositories found."
fi

# ─── 7. Local kubeconfig tidy-up ─────────────────────────────────────────────
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  run rm -f "${KUBECONFIG_FILE}"
  done_msg "Removed ${KUBECONFIG_FILE}"
fi
# In case the cluster was also added to the default kubeconfig by hand.
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CLUSTER_ARN}"; then
  run kubectl config delete-context "${CLUSTER_ARN}" || true
  run kubectl config delete-cluster "${CLUSTER_ARN}" || true
  run kubectl config unset "users.${CLUSTER_ARN}" || true
  done_msg "Removed kubeconfig context ${CLUSTER_ARN}"
fi

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
  success "Dry run complete. Nothing was deleted."
else
  success "Teardown complete."
  echo "Left in place: this app's own CDK bootstrap stack ${TOOLKIT_STACK} (qualifier ${BOOTSTRAP_QUALIFIER})."
  echo "The self-hosted variant's CDKToolkit is not touched. To remove ${TOOLKIT_STACK} as well:"
  echo "  aws cloudformation delete-stack --stack-name ${TOOLKIT_STACK} --region ${REGION}"
  echo "  then delete its retained S3 bucket cdk-${BOOTSTRAP_QUALIFIER}-assets-${ACCOUNT_ID}-${REGION} (empty it first, it is versioned)."
fi
