#!/usr/bin/env bash
# seed-example-repos.sh — push the pre-built EXAMPLE service repos into Gitea so
# they're present the moment the cluster is up, ready to onboard as "existing"
# services during the demo.
#
# Currently seeds:
#   example-repos/legacy-orders/  → lockhead/legacy-orders (PHP service)
#
# Idempotent: creates the 'lockhead' org + each repo if missing, then force-pushes
# the local example tree. Run by start.sh automatically; safe to re-run by hand.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="${SCRIPT_DIR}/example-repos"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

GITEA_USER="giteaAdmin"
GITEA_ORG="lockhead"
GITEA_LOCAL="http://localhost:${GITEA_PORT}"

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
if [[ -z "${GITEA_PASS}" ]]; then
  warn "Could not read the Gitea password — skipping example-repo seeding."
  exit 0
fi
GITEA_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "${GITEA_PASS}")

# Ensure Gitea is reachable on :${GITEA_PORT}.
_pf_pid=""
if ! curl -s -o /dev/null --max-time 3 "${GITEA_LOCAL}/api/v1/version" 2>/dev/null; then
  info "Starting a temporary Gitea port-forward on :${GITEA_PORT}..."
  kubectl port-forward -n gitea svc/my-gitea-http ${GITEA_PORT}:3000 >/dev/null 2>&1 &
  _pf_pid=$!
  trap '[[ -n "${_pf_pid}" ]] && kill "${_pf_pid}" >/dev/null 2>&1' EXIT
  sleep 3
fi

# Ensure the org exists (service repos + example repos live under it).
curl -s -o /dev/null -X POST "${GITEA_LOCAL}/api/v1/admin/users/${GITEA_USER}/orgs" \
  -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
  -d "{\"username\":\"${GITEA_ORG}\",\"full_name\":\"lockhead.cloud platform\",\"visibility\":\"public\"}" 2>/dev/null || true

seed_repo() {
  local dir="$1" name
  name="$(basename "${dir}")"
  info "Seeding example repo '${GITEA_ORG}/${name}'..."

  # Create the repo under the org (idempotent).
  local http
  http=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${GITEA_LOCAL}/api/v1/orgs/${GITEA_ORG}/repos" \
    -u "${GITEA_USER}:${GITEA_PASS}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\",\"description\":\"Example existing service (seeded for the demo)\",\"auto_init\":false,\"default_branch\":\"main\"}")
  [[ "${http}" == "201" || "${http}" == "409" ]] || warn "Unexpected HTTP ${http} creating '${name}' (continuing)."

  # Push the example tree from a throwaway working copy (never touch the source).
  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-${name}.XXXXXX")
  cp -R "${dir}/." "${work}/"
  git -C "${work}" init -b main >/dev/null 2>&1
  git -C "${work}" config user.email "demo@example.com"
  git -C "${work}" config user.name  "Demo"
  git -C "${work}" add . >/dev/null 2>&1
  git -C "${work}" commit -m "Seed example service ${name}" >/dev/null 2>&1
  git -C "${work}" remote add gitea \
    "http://${GITEA_USER}:${GITEA_PASS_ENC}@localhost:${GITEA_PORT}/${GITEA_ORG}/${name}.git"
  if git -C "${work}" push gitea main --force >/dev/null 2>&1; then
    success "Seeded ${GITEA_LOCAL}/${GITEA_ORG}/${name}"
  else
    warn "Could not push '${name}' — it may already be seeded."
  fi
  rm -rf "${work}"
}

if [[ ! -d "${EXAMPLES_DIR}" ]]; then
  warn "No example-repos/ directory — nothing to seed."
  exit 0
fi

shopt -s nullglob
for d in "${EXAMPLES_DIR}"/*/; do
  seed_repo "${d%/}"
done
shopt -u nullglob

success "Example repos seeded. Onboard one with: ./demo/onboard-existing.sh"
