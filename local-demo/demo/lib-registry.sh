#!/usr/bin/env bash
# lib-registry.sh — which container registry the demo scripts use.
#
#   default            the kind cluster's Gitea OCI registry (gitea.cnoe.localtest.me)
#   DEMO_REGISTRY=ecr  private Amazon ECR in the current AWS account/region. Set by
#                      eks-infrastructure/scripts/ui.sh. The EKS Auto Mode nodes
#                      pull from it with their node role (ECR read access).
#
# Source this file; it only defines functions.
#   registry_is_ecr
#   ecr_init                  sets AWS_REGION, ECR_HOST
#   ecr_ensure_repo <name>    creates the repository if it does not exist
#   ecr_login                 docker login to ECR (token valid 12 hours)
#   ecr_pull_secret <name> <namespace>
#                             a dockerconfigjson Secret with a fresh token, for
#                             Crossplane's package manager (it cannot use the node role)

registry_is_ecr() { [[ "${DEMO_REGISTRY:-gitea}" == "ecr" ]]; }

ecr_init() {
  command -v aws >/dev/null 2>&1 || { echo "aws CLI is required for DEMO_REGISTRY=ecr" >&2; return 1; }
  AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
  export AWS_REGION
  local account
  account=$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}") \
    || { echo "Could not call AWS (sso login needed? AWS_PROFILE=${AWS_PROFILE:-unset})" >&2; return 1; }
  ECR_HOST="${account}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

ecr_ensure_repo() {
  aws ecr describe-repositories --repository-names "$1" --region "${AWS_REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$1" --region "${AWS_REGION}" \
         --image-scanning-configuration scanOnPush=true >/dev/null
}

ecr_login() {
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_HOST}" >/dev/null
}

ecr_pull_secret() {
  local name=$1 ns=$2 token auth tmp
  token=$(aws ecr get-login-password --region "${AWS_REGION}") || return 1
  auth=$(printf 'AWS:%s' "${token}" | base64 | tr -d '\n')
  tmp=$(umask 077 && mktemp "${TMPDIR:-/tmp}/ecr-dockercfg.XXXXXX")
  printf '{"auths":{"%s":{"username":"AWS","auth":"%s"}}}' "${ECR_HOST}" "${auth}" > "${tmp}"
  kubectl create secret generic "${name}" -n "${ns}" --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${tmp}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local rc=$?
  rm -f "${tmp}"
  return ${rc}
}
