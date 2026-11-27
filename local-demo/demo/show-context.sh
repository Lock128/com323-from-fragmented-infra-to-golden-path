#!/usr/bin/env bash
# show-context.sh — which cluster the demo scripts talk to, and whether it is the cloud.
# Read-only. KUBE_CONTEXT (set by eks-infrastructure/scripts/ui.sh) is the context the
# demo scripts use; the default is the local kind cluster.
# Usage:  ./demo/show-context.sh
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
hdr() { echo -e "\n${BOLD}$*${RESET}"; }
CTX="${KUBE_CONTEXT}"
GLOBAL_CTX="$(kubectl config current-context 2>/dev/null || echo '(none)')"
SERVER="$(kubectl config view --minify --context "${CTX}" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
if [[ -z "${SERVER}" ]]; then
  echo "Context '${CTX}' is not in the kubeconfig."; exit 1
fi
KIND="unknown"
case "${CTX} ${SERVER}" in
  *arn:aws:eks*|*eks.amazonaws.com*) KIND="AWS EKS (cloud)" ;;
  *127.0.0.1*|*localhost*|*kind-*)   KIND="local kind cluster (not the cloud)" ;;
esac
hdr "The demo scripts use"
echo "  context:  ${CTX}"
echo "  server:   ${SERVER}"
if [[ "${KIND}" == AWS* ]]; then echo -e "  target:   ${GREEN}${KIND}${RESET}"; else echo -e "  target:   ${YELLOW}${KIND}${RESET}"; fi
hdr "kubeconfig current-context (global)"
echo "  ${GLOBAL_CTX}"
if [[ "${GLOBAL_CTX}" != "${CTX}" ]]; then
  echo -e "  ${YELLOW}differs from the context above; the demo scripts switch to ${CTX} before each step.${RESET}"
fi
hdr "kubectl config view --minify --context ${CTX}   (secrets are redacted)"
kubectl config view --minify --context "${CTX}" 2>&1
hdr "Nodes"
kubectl --context "${CTX}" --request-timeout=8s get nodes 2>&1 | head -8
if [[ "${KIND}" == AWS* ]] && command -v aws >/dev/null 2>&1; then
  hdr "AWS identity of this shell"
  aws sts get-caller-identity --output text --query '[Account,Arn]' 2>&1 | head -3
fi
