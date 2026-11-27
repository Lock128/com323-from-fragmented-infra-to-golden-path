#!/usr/bin/env bash
# Deletes the local demo cluster completely and rebuilds from scratch.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

echo "re:Invent 2026 — Full Cluster Recreate"
echo "─────────────────────────────────"

# ─── confirm ──────────────────────────────────────────────────────────────────
warn "This will DESTROY the kind cluster '${DEMO_NAME}' and the local repos/ directory."
read -r -p "Type 'yes' to continue: " _confirm || _confirm=""
if [[ "${_confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

# ─── delete ───────────────────────────────────────────────────────────────────
info "Deleting kind cluster '${DEMO_NAME}'..."

if command -v idpbuilder >/dev/null 2>&1; then
  demo_idpbuilder delete --name ${DEMO_NAME} 2>/dev/null || true
else
  command -v kind >/dev/null 2>&1 && kind delete cluster --name ${DEMO_NAME} 2>/dev/null || true
fi

# Remove the kubeconfig context so start.sh doesn't skip the create step
demo_forget_kubeconfig

success "Cluster deleted."

# ─── clean local git repos ────────────────────────────────────────────────────
# setup_gitops.sh creates repos/ — wipe it so it's re-initialized cleanly.
if [[ -d "${SCRIPT_DIR}/repos" ]]; then
  info "Removing repos/ (will be re-created by setup_gitops.sh)..."
  rm -rf "${SCRIPT_DIR}/repos"
  success "repos/ removed."
fi

# ─── rebuild ──────────────────────────────────────────────────────────────────
info "Rebuilding from scratch..."
"${SCRIPT_DIR}/start.sh"

info "Setting up GitOps (Gitea repos + ArgoCD Applications)..."
"${SCRIPT_DIR}/setup_gitops.sh"

info "Starting UIs..."
bash "${SCRIPT_DIR}/ui.sh" || warn "ui.sh failed — run it manually: ./ui.sh"
