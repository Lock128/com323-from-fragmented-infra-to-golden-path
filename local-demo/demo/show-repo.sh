#!/usr/bin/env bash
# show-repo.sh — the repository the platform created for the service.
# Usage:  ./demo/show-repo.sh <service-name>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"
GITEA_USER="giteaAdmin"   # auth user
GITEA_ORG="lockhead"      # repo owner (service repos live under this org)
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
hdr() { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)

echo -e "${BOLD}Repository the platform created for '${NAME}'${RESET}"
echo "──────────────────────────────────────────────────"

hdr "Repo exists in Gitea"
echo -e "${DIM}GET ${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${NAME}${RESET}"
curl -s -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${NAME}" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  full_name:", d.get("full_name")); print("  html_url: ", d.get("html_url")); print("  default_branch:", d.get("default_branch"))' \
  2>/dev/null || echo "  (repo not found — did onboarding run?)"

hdr "What the platform scaffolded into it"
echo -e "${DIM}GET .../contents  (top-level tree)${RESET}"
curl -s -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${NAME}/contents" \
  | python3 -c 'import sys,json; [print("  •", e["name"], "(dir)" if e["type"]=="dir" else "") for e in json.load(sys.stdin)]' \
  2>/dev/null || echo "  (could not list contents)"

hdr "The CI/CD pipeline the developer never wrote"
echo -e "${DIM}GET .../contents/.gitea/workflows/ci.yaml${RESET}"
curl -s -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_LOCAL}/api/v1/repos/${GITEA_ORG}/${NAME}/contents/.gitea/workflows/ci.yaml" \
  | python3 -c 'import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode())' \
  2>/dev/null | sed 's/^/  /' || echo "  (workflow not found)"

echo ""
echo -e "${BOLD}Open it:${RESET}  ${GITEA_LOCAL}/${GITEA_ORG}/${NAME}"
