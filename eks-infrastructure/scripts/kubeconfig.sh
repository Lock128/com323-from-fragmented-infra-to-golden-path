# shellcheck shell=bash
# kubeconfig.sh — the self-managed EKS cluster gets its OWN kubeconfig file, so the
# scripts in this folder never change the current context of ~/.kube/config (and
# never flip the local kind demo or the managed variant).
#
#   source "$(dirname "${BASH_SOURCE[0]}")/kubeconfig.sh"
#   eks_use_kubeconfig      export KUBECONFIG=<file>, creating the file if it is missing
#   eks_write_kubeconfig    (re)write the file with `aws eks update-kubeconfig`
#
# Settings (environment):
#   CLUSTER_NAME     default: context.idp.clusterName in ../cdk.json (lockheadcloud-idp)
#   AWS_REGION       default: us-west-2
#   IDP_AWS_PROFILE  AWS profile written into the kubeconfig (default: the shell's AWS_PROFILE)
#   MASTERS_ROLE_ARN optional --role-arn for the kubeconfig
#   EKS_KUBECONFIG   default: ~/.kube/<CLUSTER_NAME>
_eks_app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$(node -p "require('${_eks_app_dir}/cdk.json').context.idp.clusterName" 2>/dev/null || true)"
  CLUSTER_NAME="${CLUSTER_NAME:-lockheadcloud-idp}"
fi
AWS_REGION="${AWS_REGION:-us-west-2}"
EKS_KUBECONFIG="${EKS_KUBECONFIG:-${HOME}/.kube/${CLUSTER_NAME}}"
unset _eks_app_dir

eks_write_kubeconfig() {
  local args=(--name "${CLUSTER_NAME}" --region "${AWS_REGION}" --kubeconfig "${EKS_KUBECONFIG}")
  # Profile: IDP_AWS_PROFILE, else the one already in the file, else the shell's AWS_PROFILE.
  local profile="${IDP_AWS_PROFILE:-}"
  if [[ -z "${profile}" && -s "${EKS_KUBECONFIG}" ]]; then
    profile="$(kubectl --kubeconfig "${EKS_KUBECONFIG}" config view --minify \
      -o jsonpath='{.users[0].user.exec.env[?(@.name=="AWS_PROFILE")].value}' 2>/dev/null || true)"
  fi
  profile="${profile:-${AWS_PROFILE:-}}"
  [[ -n "${profile}" ]] && args+=(--profile "${profile}")
  [[ -n "${MASTERS_ROLE_ARN:-}" ]] && args+=(--role-arn "${MASTERS_ROLE_ARN}")
  mkdir -p "$(dirname "${EKS_KUBECONFIG}")"
  # Explicit return: callers use this in `a || b` lists, where set -e does not apply.
  aws eks update-kubeconfig "${args[@]}" >/dev/null || return 1
  chmod 600 "${EKS_KUBECONFIG}" 2>/dev/null || true
}

# Older versions of these scripts wrote the cluster into ~/.kube/config. If that
# context is still there, copy it out (keeps its AWS_PROFILE, no AWS call needed).
_eks_copy_from_default() {
  local ctx tmp
  ctx="$(env -u KUBECONFIG kubectl config get-contexts -o name 2>/dev/null \
    | grep -E "^arn:aws:eks:${AWS_REGION}:[0-9]+:cluster/${CLUSTER_NAME}\$" | head -1 || true)"
  [[ -n "${ctx}" ]] || return 1
  mkdir -p "$(dirname "${EKS_KUBECONFIG}")"
  tmp="$(mktemp "${EKS_KUBECONFIG}.XXXXXX")"
  if env -u KUBECONFIG kubectl config view --raw --minify --flatten --context "${ctx}" > "${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}"; mv "${tmp}" "${EKS_KUBECONFIG}"
    KUBECONFIG="${EKS_KUBECONFIG}" kubectl config use-context "${ctx}" >/dev/null 2>&1 || true
    return 0
  fi
  rm -f "${tmp}"; return 1
}

eks_use_kubeconfig() {
  if [[ ! -s "${EKS_KUBECONFIG}" ]]; then
    _eks_copy_from_default || eks_write_kubeconfig || {
      echo "Could not create ${EKS_KUBECONFIG}: is ${CLUSTER_NAME} deployed in ${AWS_REGION}, and are you signed in to AWS?" >&2
      return 1
    }
  fi
  export KUBECONFIG="${EKS_KUBECONFIG}"
}
