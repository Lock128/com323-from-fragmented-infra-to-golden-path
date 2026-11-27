#!/usr/bin/env bash
# Full cluster rebuild — Direct mode (no GitOps, no Gitea push, plain kubectl apply).
# Use this instead of recreate.sh when you want Option B for the demo.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

echo "re:Invent 2026 — Full Cluster Recreate (Direct Mode)"
echo "────────────────────────────────────────────────"

# ─── confirm ──────────────────────────────────────────────────────────────────
warn "This will DESTROY the kind cluster '${DEMO_NAME}'."
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

demo_forget_kubeconfig

success "Cluster deleted."

# ─── rebuild ──────────────────────────────────────────────────────────────────
info "Rebuilding from scratch..."
"${SCRIPT_DIR}/start.sh"

info "Applying platform API directly (XRDs + Compositions)..."
"${SCRIPT_DIR}/setup_direct.sh"

info "Starting UIs..."
bash "${SCRIPT_DIR}/ui.sh" || warn "ui.sh failed — run it manually: ./ui.sh"
