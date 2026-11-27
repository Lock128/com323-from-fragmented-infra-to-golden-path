#!/usr/bin/env bash
# Bootstraps the re:Invent 2026 local demo environment.
# Uses CNOE idpbuilder for the cluster baseline (kind + Argo CD + Gitea +
# Backstage), then installs Crossplane so the service-onboarding golden path
# can run. The platform API (Service XRD + Composition) is applied by
# setup_gitops.sh / setup_direct.sh afterwards.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="${SCRIPT_DIR}/packages"

# ─── DNS resolvers for kind nodes / CoreDNS ───────────────────────────────────
# Which upstream DNS the kind nodes and CoreDNS forward to for image pulls.
#
# There is NO single correct resolver: Google DNS (8.8.8.8) is blocked on some
# corporate / VPN networks (queries time out → every image pull fails at name
# resolution), while Docker Desktop's internal DNS is blocked on others. The IP
# of a working resolver also changes with the network (home vs. conference wifi
# vs. hotel), so we do NOT hardcode one.
#
# Instead, discover_dns_servers() (below) probes a prioritised list of candidate
# resolvers from *inside a kind node* and picks the first that can actually
# resolve a real registry host. Set DNS_SERVERS explicitly to skip discovery:
#   DNS_SERVERS="8.8.8.8 8.8.4.4" ./start.sh
#
# Empty by default — resolved lazily on first use via ensure_dns_servers().
DNS_SERVERS="${DNS_SERVERS:-}"

# Host to resolve when testing whether a candidate resolver actually works.
# A real registry host, so a positive result means image pulls will succeed.
DNS_PROBE_HOST="${DNS_PROBE_HOST:-quay.io}"

# ─── colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# ─── progress tracking ────────────────────────────────────────────────────────
SCRIPT_START=0
TOTAL_STEPS=14
CURRENT_STEP=0

elapsed_fmt() {
  local secs=$(( $(date +%s) - SCRIPT_START ))
  printf '%d:%02d' $(( secs / 60 )) $(( secs % 60 ))
}

print_step() {
  local description="$1" expected="$2"
  (( CURRENT_STEP++ )) || true
  local bar=""
  local i=0
  while [[ $i -lt $CURRENT_STEP ]]; do bar+="█"; (( i++ )); done
  while [[ $i -lt $TOTAL_STEPS ]];  do bar+="░"; (( i++ )); done
  echo -e "\n${BOLD}${CYAN}[$(elapsed_fmt)]  [${CURRENT_STEP}/${TOTAL_STEPS}]  ${bar}${RESET}"
  echo -e "${BOLD}▶ ${description}${RESET}  ${DIM}(expected: ~${expected})${RESET}"
}

# ─── prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."
  local missing=()

  command -v docker    >/dev/null 2>&1 || missing+=("docker")
  command -v helm      >/dev/null 2>&1 || missing+=("helm")
  command -v kubectl   >/dev/null 2>&1 || missing+=("kubectl")
  command -v idpbuilder >/dev/null 2>&1 || missing+=("idpbuilder")

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing tools: ${missing[*]}
    Install missing tools:
      docker:      https://www.docker.com/get-started/
      helm:        brew install helm
      kubectl:     brew install kubectl
      idpbuilder:  brew install cnoe-io/tap/idpbuilder
                   — or — curl -fsSL https://raw.githubusercontent.com/cnoe-io/idpbuilder/main/hack/install.sh | bash"
  fi

  docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker and try again."
  success "All prerequisites found."
}

# ─── cluster ─────────────────────────────────────────────────────────────────
create_cluster() {
  # A cluster made earlier lives in ~/.kube/config; make sure this instance's own kubeconfig has it.
  demo_import_kubeconfig 2>/dev/null || true
  if kubectl config get-contexts ${KUBE_CONTEXT} >/dev/null 2>&1; then
    warn "${KUBE_CONTEXT} context already exists — skipping idpbuilder create."
    warn "Run ./stop.sh first if you want a fresh cluster."
    kubectl config use-context ${KUBE_CONTEXT}
    return
  fi

  info "Creating local IDP cluster with idpbuilder (CNOE baseline)..."
  info "This installs kind + ArgoCD + Gitea. First run may take a few minutes."
  # --name sets the kind cluster/pod prefix (→ context ${KUBE_CONTEXT}).
  # --port moves idpbuilder's published web-UI host port off the default (8443)
  # so this demo can run ALONGSIDE another idpbuilder cluster (e.g. the CLC
  # 'localdev' one) without a collision. Override via IDP_PORT if ${IDP_PORT} clashes.
  #
  # --kind-config: idpbuilder's built-in kind template HARDCODES a host-port
  # mapping for the gitea NodePort on 32222 — neither --port nor --extra-ports
  # removes it, so two idpbuilder clusters otherwise collide with
  # "Bind for 0.0.0.0:32222 failed: port is already allocated". kind-config.yaml
  # is a faithful copy of the upstream default that moves ONLY that host port to
  # ${GITEA_HOST_PORT} (override via GITEA_HOST_PORT). idpbuilder still renders the template
  # placeholders and injects the ingress port/label itself.
  #
  # IMPORTANT (self-heal): idpbuilder BLOCKS until ingress-nginx is Ready, but
  # behind a corporate proxy (Zscaler) ingress-nginx can't pull its image until
  # we (a) fix node DNS and (b) inject the proxy CA into the node trust store.
  # Chicken-and-egg. So we run idpbuilder in the background, wait for the kind
  # node container to appear, heal its networking immediately, THEN let
  # idpbuilder finish. On a clean network the heal is a harmless no-op.
  # Build the kind config, substituting the gitea host port if overridden.
  # kind-config.yaml ships with the template's default gitea host port (32223);
  # render a per-instance copy with this instance's GITEA_HOST_PORT (instance.env).
  local kind_config rendered_config
  rendered_config=$(mktemp "${TMPDIR:-/tmp}/${DEMO_NAME}-kind-config.XXXXXX")
  sed "s/hostPort: 32223/hostPort: ${GITEA_HOST_PORT}/" \
    "${SCRIPT_DIR}/kind-config.yaml" > "${rendered_config}"
  kind_config="${rendered_config}"
  info "Using kind-config (gitea host port → ${GITEA_HOST_PORT}) to avoid 32222 collision."

  # idpbuilder reads/writes ~/.kube/config only (see instance.env), so it runs without KUBECONFIG.
  demo_idpbuilder create \
    --name ${DEMO_NAME} \
    --port "${IDP_PORT}" \
    --kind-config "${kind_config}" &
  local idp_pid=$!

  # Wait (up to ~2 min) for idpbuilder to create the kind node container.
  info "Waiting for kind node container to appear (so we can heal its networking)..."
  local waited=0
  while ! docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" \
      --format "{{.Names}}" 2>/dev/null | grep -q .; do
    # If idpbuilder already exited (e.g. failed fast), stop waiting.
    if ! kill -0 "${idp_pid}" 2>/dev/null; then break; fi
    sleep 3
    (( waited += 3 ))
    if [[ ${waited} -ge 120 ]]; then
      warn "kind node did not appear within 120s — continuing without early heal."
      break
    fi
  done

  # Heal node networking early (DNS + proxy CA) so image pulls succeed while
  # idpbuilder is still waiting on ingress-nginx. Idempotent; safe on clean nets.
  if docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" \
      --format "{{.Names}}" 2>/dev/null | grep -q .; then
    info "kind node up — applying early DNS + proxy-CA heal..."
    fix_node_dns
    inject_proxy_ca || warn "Early CA injection failed — will retry after cluster is up."
  fi

  # Now block until idpbuilder finishes bootstrapping (ArgoCD + Gitea + ingress).
  info "Waiting for idpbuilder to finish bootstrapping..."
  if ! wait "${idp_pid}"; then
    die "idpbuilder create failed. Check output above (common causes: port collision, Docker not running, image pulls blocked)."
  fi

  demo_import_kubeconfig || warn "Could not copy ${KUBE_CONTEXT} into ${DEMO_KUBECONFIG:-the kubeconfig}."
  kubectl config use-context ${KUBE_CONTEXT}
  success "Cluster ready: ${KUBE_CONTEXT} (web UIs on :${IDP_PORT})"
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────
# idpbuilder's ArgoCD redirects HTTP → HTTPS by default, which breaks a plain
# port-forward on :80 (browser follows redirect to https://localhost:${ARGOCD_PORT} and
# gets a cert error). Patch argocd-server with --insecure so it serves plain
# HTTP — correct and standard for a local dev cluster.
patch_argocd_insecure() {
  info "Patching argocd-server to serve plain HTTP (--insecure)..."
  kubectl patch deployment argocd-server -n argocd \
    --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["/usr/local/bin/argocd-server","--insecure"]}]' \
    2>/dev/null || true

  # Only wait for rollout if the patch actually changed something
  kubectl rollout status deployment/argocd-server -n argocd --timeout=90s 2>/dev/null || true
  success "argocd-server: plain HTTP on port 80."
}

# ─── DNS auto-discovery ───────────────────────────────────────────────────────
# Pick a DNS resolver that actually works on the current network, instead of
# hardcoding one (which breaks when the network changes — home vs. re:Invent
# wifi vs. a hotel). Strategy: build a prioritised candidate list, then probe
# each candidate from INSIDE a kind node (the environment that matters for
# containerd image pulls) and keep the first set that resolves DNS_PROBE_HOST.

# Return the first running kind node name, or empty if none exists yet.
_first_kind_node() {
  docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" \
    --format "{{.Names}}" 2>/dev/null | head -1
}

# Test whether a SPECIFIC resolver can resolve DNS_PROBE_HOST, from inside a node.
# We send a direct UDP DNS A-query to the candidate IP on :53 rather than using
# getent/nslookup — the kind node caches DNS and routes libc lookups through a
# path that ignores the resolver we want to test, so getent reports success even
# for a dead resolver. A direct query to the IP is the only reliable signal.
# python3 is always present in the kind node image (dig/nslookup are not).
# Args: <node> <resolver-ip>.  Returns 0 if that resolver answers with an A record.
_resolver_works_on_node() {
  local node="$1" resolver="$2"
  docker exec -i "${node}" python3 - "${resolver}" "${DNS_PROBE_HOST}" <<'PY' >/dev/null 2>&1
import socket, struct, sys, random
resolver, host = sys.argv[1], sys.argv[2]
# Build a minimal DNS query packet for an A record.
tid = random.randint(0, 0xFFFF)
header = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)  # RD=1, 1 question
qname = b"".join(struct.pack("B", len(p)) + p.encode()
                  for p in host.split(".")) + b"\x00"
question = qname + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN
packet = header + question
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
try:
    s.sendto(packet, (resolver, 53))
    data, _ = s.recvfrom(512)
except Exception:
    sys.exit(1)
# Must match our transaction id and report at least one answer (ANCOUNT > 0).
if len(data) < 8 or data[0:2] != packet[0:2]:
    sys.exit(1)
ancount = struct.unpack(">H", data[6:8])[0]
sys.exit(0 if ancount > 0 else 1)
PY
}

# Resolve DNS_SERVERS once by probing candidates against a real kind node.
# No-op if DNS_SERVERS is already set (explicit override, or already discovered).
#
# IMPORTANT — why we don't enumerate the host's per-network resolvers:
# On this setup Docker Desktop (and VPNs like Tailscale) transparently intercept
# outbound port-53 traffic from the node. A query to ALMOST any resolver IP gets
# answered locally and forwarded to whatever DNS the host currently uses — so the
# specific resolver IP is irrelevant, and the Docker Desktop resolver 192.168.65.7
# automatically tracks the current network (home, conference wifi, hotel) without
# us ever naming a network-specific IP. The ONE thing interception does NOT cover
# is a resolver the network actively blocks (e.g. 8.8.8.8 on a corporate net),
# which shows up as a probe timeout. So the strategy is:
#   1. Use 192.168.65.7 if it answers (the normal, network-agnostic path).
#   2. Only if that times out, fall back to public resolvers that still answer.
ensure_dns_servers() {
  [[ -n "${DNS_SERVERS}" ]] && return 0

  local node; node="$(_first_kind_node)"

  # No node yet (very early heal): default without probing; re-verified later
  # on the second fix_node_dns pass once the node exists.
  if [[ -z "${node}" ]]; then
    DNS_SERVERS="192.168.65.7"
    info "No kind node to probe yet — defaulting to ${DNS_SERVERS} (re-verified once the node is up)."
    return 0
  fi

  info "Discovering a working DNS resolver (probing from node ${node})..."

  # Priority order: Docker Desktop resolver first (network-agnostic), then public
  # resolvers as a fallback for networks that block the Docker path.
  local candidates=("192.168.65.7" "1.1.1.1" "8.8.8.8")
  local cand
  for cand in "${candidates[@]}"; do
    if _resolver_works_on_node "${node}" "${cand}"; then
      DNS_SERVERS="${cand}"
      success "DNS resolver discovered: ${DNS_SERVERS} (resolves ${DNS_PROBE_HOST})"
      return 0
    fi
    info "  candidate ${cand} did not answer — trying next..."
  done

  # Nothing answered — keep going with the Docker Desktop resolver and warn.
  DNS_SERVERS="192.168.65.7"
  warn "No candidate resolver answered the probe. Falling back to ${DNS_SERVERS}."
  warn "If image pulls fail, set a known-good resolver: DNS_SERVERS='<ip>' ./start.sh"
  return 0
}

# ─── DNS fix ─────────────────────────────────────────────────────────────────
# Fix DNS at two levels so image pulls succeed on any network:
#   1. CoreDNS (pod-to-pod DNS inside the cluster)
#   2. /etc/resolv.conf on each kind node (used by containerd for image pulls)
# The actual resolver is chosen by ensure_dns_servers() (auto-discovery), unless
# DNS_SERVERS was set explicitly in the environment.
fix_node_dns() {
  demo_import_kubeconfig 2>/dev/null || true   # no-op until the context exists
  ensure_dns_servers

  # Explicitly target our context. During the early-heal pass the context may not
  # be in kubeconfig yet — the CoreDNS patch then no-ops (|| warn) while the
  # node-level resolv.conf patch below (docker exec, label-scoped) still runs,
  # which is the part that actually unblocks containerd image pulls.
  local kctx="${KUBE_CONTEXT}"
  info "Patching CoreDNS to forward to: ${DNS_SERVERS} (bypasses Docker Desktop DNS)..."
  kubectl --context "${kctx}" patch configmap coredns -n kube-system --patch "
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . ${DNS_SERVERS}
        cache 30
        loop
        reload
        loadbalance
    }
" 2>/dev/null || warn "CoreDNS patch failed — continuing."

  # Force-delete old pods so the rollout completes immediately rather than waiting
  # for a graceful termination that may stall when DNS itself is broken.
  kubectl --context "${kctx}" delete pods -n kube-system -l k8s-app=kube-dns --force --grace-period=0 2>/dev/null || true

  info "Patching /etc/resolv.conf on kind nodes (for containerd image pulls)..."
  # idpbuilder bundles kind internally so the 'kind' CLI may not be in PATH.
  # Use Docker labels to find nodes — works regardless of whether kind is installed.
  local nodes
  nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" --format "{{.Names}}" 2>/dev/null)
  if [[ -z "${nodes}" ]]; then
    warn "No kind nodes found via Docker — skipping node DNS patch."
    return
  fi
  # Build the resolv.conf body from DNS_SERVERS (one nameserver line per entry).
  local resolv_body=""
  for ns in ${DNS_SERVERS}; do
    resolv_body+="nameserver ${ns}"$'\n'
  done
  for node in ${nodes}; do
    docker exec "${node}" bash -c \
      "printf '%s' '${resolv_body}' > /etc/resolv.conf" 2>/dev/null || true
  done
  success "DNS patched on cluster and nodes (${DNS_SERVERS})."
}

# ─── Zscaler / corporate proxy CA injection ───────────────────────────────────
# If Zscaler (or any corporate SSL-inspection proxy) is active, kind node
# containers won't trust xpkg.upbound.io and image pulls fail with
# "x509: certificate signed by unknown authority". Export the CA from the
# macOS keychain and inject it into every kind node's trust store.
inject_proxy_ca() {
  demo_import_kubeconfig 2>/dev/null || true
  # Robust temp file: template X's MUST be at the end (BSD/macOS mktemp), and we
  # mktemp a directory to avoid stale /tmp/proxy-ca.* collisions from prior runs.
  local ca_dir ca_pem
  ca_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxy-ca.XXXXXX")
  ca_pem="${ca_dir}/zscaler.pem"
  trap "rm -rf ${ca_dir}" RETURN

  # macOS: search System keychain first, then the login keychain, for Zscaler certs.
  security find-certificate -a -p -c "Zscaler" \
    /Library/Keychains/System.keychain 2>/dev/null > "${ca_pem}" || true
  if [[ ! -s "${ca_pem}" ]]; then
    security find-certificate -a -p -c "Zscaler" \
      "${HOME}/Library/Keychains/login.keychain-db" 2>/dev/null >> "${ca_pem}" || true
  fi

  if [[ ! -s "${ca_pem}" ]]; then
    info "No Zscaler certificate found in keychains — skipping CA injection (fine on a clean network)."
    return
  fi

  local cert_count
  cert_count=$(grep -c "BEGIN CERTIFICATE" "${ca_pem}")
  info "Injecting ${cert_count} Zscaler CA cert(s) into kind node trust stores..."

  # idpbuilder bundles kind internally — use Docker labels instead of 'kind' CLI.
  local nodes
  nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" --format "{{.Names}}" 2>/dev/null)
  if [[ -z "${nodes}" ]]; then
    warn "No kind nodes found via Docker — skipping CA injection."
    return
  fi

  for node in ${nodes}; do
    docker cp "${ca_pem}" "${node}:/usr/local/share/ca-certificates/zscaler.crt" || continue
    docker exec "${node}" update-ca-certificates --fresh >/dev/null 2>&1 || true
    # kind nodes use systemd; fall back to sending SIGHUP if systemctl is unavailable
    docker exec "${node}" systemctl restart containerd 2>/dev/null || \
      docker exec "${node}" kill -s HUP "$(docker exec "${node}" cat /run/containerd/containerd.pid 2>/dev/null)" 2>/dev/null || true
  done

  # Kick any pods already stuck in ImagePullBackOff so they re-pull now that the
  # node trusts the proxy CA (kubelet's own backoff can otherwise take minutes).
  # No-op if the context/namespaces aren't there yet (early-heal pass).
  local kctx="${KUBE_CONTEXT}"
  kubectl --context "${kctx}" -n ingress-nginx delete pod --all --force --grace-period=0 2>/dev/null || true
  kubectl --context "${kctx}" -n gitea delete pod --all --force --grace-period=0 2>/dev/null || true

  success "Proxy CA injected and containerd restarted on all nodes."
}

# ─── Crossplane ───────────────────────────────────────────────────────────────
install_crossplane() {
  info "Installing Crossplane 2.4.0 via Helm..."
  helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update >/dev/null

  helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system \
    --create-namespace \
    --version 2.4.0 \
    --set args='{--enable-usages}' \
    --wait --timeout 5m
  success "Crossplane installed."
}

wait_for_crossplane() {
  info "Waiting for Crossplane pods to be ready..."
  kubectl wait --for=condition=Available deployment/crossplane \
    -n crossplane-system --timeout=120s
  kubectl wait --for=condition=Available deployment/crossplane-rbac-manager \
    -n crossplane-system --timeout=120s
  success "Crossplane is healthy."
}

# ─── crossplane pod CA trust ──────────────────────────────────────────────────
# Crossplane's package manager makes outbound HTTPS calls from inside the pod
# (Go TLS stack). The node-level CA injection in inject_proxy_ca fixes containerd
# but not the crossplane pod itself. Patch the deployment to add the Zscaler CA
# to Go's SSL_CERT_DIR so xpkg.upbound.io resolves correctly behind a proxy.
patch_crossplane_ca() {
  # Idempotent: skip if already patched
  if kubectl get deployment crossplane -n crossplane-system \
      -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null \
      | grep -q "SSL_CERT_DIR"; then
    info "Crossplane CA already patched — skipping."
    return 0
  fi

  local tmp_cert
  tmp_cert=$(mktemp /tmp/zscaler-crossplane.XXXXXX.crt)
  trap "rm -f ${tmp_cert}" RETURN

  if ! docker cp ${DEMO_NAME}-control-plane:/usr/local/share/ca-certificates/zscaler.crt "${tmp_cert}" 2>/dev/null; then
    info "No proxy CA on kind node — skipping crossplane CA patch."
    return 0
  fi

  info "Patching Crossplane deployment to trust proxy CA (SSL_CERT_DIR)..."

  kubectl create configmap zscaler-ca -n crossplane-system \
    --from-file=zscaler.crt="${tmp_cert}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Strategic merge: merges by name key, safe to re-apply
  kubectl patch deployment crossplane -n crossplane-system --type=strategic --patch='{
    "spec":{"template":{"spec":{
      "volumes":[{"name":"zscaler-ca","configMap":{"name":"zscaler-ca"}}],
      "containers":[{"name":"crossplane",
        "env":[{"name":"SSL_CERT_DIR","value":"/etc/ssl/certs:/etc/ssl/custom-ca"}],
        "volumeMounts":[{"name":"zscaler-ca","mountPath":"/etc/ssl/custom-ca","readOnly":true}]
      }]
    }}}}'

  kubectl rollout status deployment/crossplane -n crossplane-system --timeout=90s
  success "Crossplane proxy CA injected."
}

# ─── providers & functions ────────────────────────────────────────────────────
install_providers() {
  info "Installing provider-kubernetes and function-patch-and-transform..."
  kubectl apply -f "${PACKAGES}/1-crossplane/providers.yaml"
  kubectl apply -f "${PACKAGES}/1-crossplane/functions.yaml"

  info "Waiting for provider-kubernetes to be installed (image pull may take a minute)..."
  kubectl wait provider/provider-kubernetes \
    --for=condition=Installed --timeout=5m
  kubectl wait provider/provider-kubernetes \
    --for=condition=Healthy --timeout=5m

  info "Waiting for function-patch-and-transform to be installed..."
  kubectl wait function/function-patch-and-transform \
    --for=condition=Installed --timeout=5m
  kubectl wait function/function-patch-and-transform \
    --for=condition=Healthy --timeout=5m

  success "Provider and function are healthy."
}

bind_provider_rbac() {
  info "Binding cluster-admin to provider-kubernetes service account..."

  local sa_name
  sa_name=$(kubectl get serviceaccount -n crossplane-system \
    -o name 2>/dev/null | grep "provider-kubernetes" | head -1 | cut -d/ -f2)

  if [[ -z "${sa_name}" ]]; then
    warn "provider-kubernetes SA not found yet — retrying in 10s..."
    sleep 10
    sa_name=$(kubectl get serviceaccount -n crossplane-system \
      -o name 2>/dev/null | grep "provider-kubernetes" | head -1 | cut -d/ -f2)
  fi

  [[ -z "${sa_name}" ]] && die "Could not find provider-kubernetes ServiceAccount in crossplane-system."

  kubectl create clusterrolebinding crossplane-provider-kubernetes-admin \
    --clusterrole=cluster-admin \
    --serviceaccount="crossplane-system:${sa_name}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${PACKAGES}/1-crossplane/providerconfig.yaml"
  success "RBAC bound for ${sa_name}."
}

# ─── downstream-system namespaces ─────────────────────────────────────────────
# The service-onboarding Composition registers each new service with three
# "downstream systems" by creating ConfigMaps in these namespaces. They stand in
# for real security-scanning, SRE/on-call, and reporting platforms. Precreate
# them so the composition's registration objects have a home.
create_platform_namespaces() {
  info "Creating downstream-system namespaces (security / SRE / reporting)..."
  for ns in security-system sre-system platform-reporting; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${ns}" lockhead.cloud/platform-system=true --overwrite >/dev/null 2>&1 || true
  done
  success "Downstream-system namespaces ready."
}

# ─── crossview ────────────────────────────────────────────────────────────────
install_crossview() {
  info "Adding Crossview Helm repo..."
  helm repo add crossview https://crossplane-contrib.github.io/crossview --force-update 2>/dev/null || true
  helm repo update crossview 2>/dev/null || true

  info "Installing Crossview (Crossplane resource browser)..."
  # auth.mode=none: no login required — fine for a local demo
  helm upgrade --install crossview crossview/crossview \
    --namespace crossview-system \
    --create-namespace \
    --set "config.server.auth.mode=none" \
    --set "secrets.dbPassword=crossview-demo" \
    --set "secrets.sessionSecret=$(openssl rand -base64 32)" \
    --wait \
    --timeout 5m
  success "Crossview installed — access via: kubectl port-forward -n crossview-system svc/crossview-service ${CROSSVIEW_PORT}:80"
}

# ─── backstage ────────────────────────────────────────────────────────────────
install_backstage() {
  # Skip only if both backstage AND dex are already present
  if kubectl get deployment backstage -n backstage >/dev/null 2>&1 && \
     kubectl get deployment dex -n backstage >/dev/null 2>&1; then
    info "Backstage and Dex already installed — skipping."
    return 0
  fi

  info "Creating Backstage namespace and secrets..."

  # backstage-env-vars: PostgreSQL connection + Gitea GITEA_USERNAME env key
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic backstage-env-vars \
    --namespace backstage \
    --from-literal=POSTGRES_HOST=postgresql.backstage.svc.cluster.local \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_DB=backstage \
    --from-literal=POSTGRES_USER=backstage \
    --from-literal=POSTGRES_PASSWORD=backstage-demo \
    --dry-run=client -o yaml | kubectl apply -f -

  # gitea-credentials: copy username + password from idpbuilder's gitea-credential secret
  local gitea_user gitea_pass
  gitea_user=$(kubectl get secret -n gitea gitea-credential \
    -o jsonpath='{.data.username}' | base64 -d)
  gitea_pass=$(kubectl get secret -n gitea gitea-credential \
    -o jsonpath='{.data.password}' | base64 -d)
  kubectl create secret generic gitea-credentials \
    --namespace backstage \
    --from-literal=GITEA_USERNAME="${gitea_user}" \
    --from-literal=GITEA_PASSWORD="${gitea_pass}" \
    --dry-run=client -o yaml | kubectl apply -f -

  info "Applying Backstage manifests (PostgreSQL + Backstage Deployment)..."
  # install.yaml carries the original browser ports (7107 / 5656); render this instance's.
  demo_rewrite_ports < "${PACKAGES}/5-backstage/install.yaml" | kubectl apply -f -

  info "Waiting for PostgreSQL to be ready..."
  kubectl wait pod -n backstage -l app=postgresql \
    --for=condition=Ready --timeout=3m

  info "Waiting for Dex OIDC provider to be ready..."
  kubectl wait deployment/dex -n backstage \
    --for=condition=Available --timeout=3m

  info "Waiting for Backstage to be ready (image pull from ghcr.io may take a minute)..."
  kubectl wait deployment/backstage -n backstage \
    --for=condition=Available --timeout=5m
  success "Backstage ready — http://localhost:${BACKSTAGE_PORT}   (sign in: demo@example.com / password)"
}

# Platform API (XRDs + Compositions) is deployed through GitOps after this script.
# Run ./setup_gitops.sh once start.sh completes to wire up Gitea + ArgoCD.

# ─── cheatsheet ───────────────────────────────────────────────────────────────
print_cheatsheet() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║   Cluster is ready — choose your demo mode below            ║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}What was installed:${RESET}"
  echo "  ✓ kind cluster (${KUBE_CONTEXT}) via idpbuilder"
  echo "  ✓ ArgoCD + Gitea (idpbuilder baseline)"
  echo "  ✓ Crossplane 2.4.0 + provider-kubernetes"
  echo "  ✓ Downstream-system namespaces (security-system, sre-system, platform-reporting)"
  echo "  ✓ Crossview (Crossplane resource browser)"
  echo "  ✓ Backstage (developer portal — golden-path template wired after setup)"
  echo ""
  echo -e "${BOLD}Next: install the platform API + wire Backstage${RESET}"
  echo "  1. ./setup_gitops.sh   → pushes XRD+Composition to Gitea, ArgoCD installs them,"
  echo "                            registers the service-onboarding template in Backstage"
  echo "  2. ./ui.sh             → opens ArgoCD / Gitea / Backstage / Crossview"
  echo ""
  echo -e "${BOLD}Then run the golden-path demo (service onboarding):${RESET}"
  echo "  Portal path (what you show on stage):"
  echo "    Backstage → Create → 'Onboard a new service' → fill form → Create"
  echo "  Scripted path (fast / offline fallback):"
  echo "    ./demo/onboard-service.sh checkout storefront   # name team"
  echo "    ./demo/show-repo.sh checkout                     # the repo the platform created"
  echo "    ./demo/show-deploy.sh checkout storefront        # ArgoCD app + running workload"
  echo "    ./demo/show-registrations.sh checkout            # security / SRE / reporting"
  echo ""
  echo -e "${BOLD}UIs:${RESET}"
  echo "  ./ui.sh  →  ArgoCD: http://localhost:${ARGOCD_PORT}   |  Gitea: http://localhost:${GITEA_PORT}"
  echo "             Backstage: http://localhost:${BACKSTAGE_PORT} (demo@example.com / password)  |  Crossview: http://localhost:${CROSSVIEW_PORT}"
  echo ""
  echo -e "${BOLD}Cleanup:${RESET}  ./stop.sh"
  echo ""
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  SCRIPT_START=$(date +%s)
  CURRENT_STEP=0

  echo -e "${BOLD}re:Invent 2026 — Local Demo Bootstrap${RESET}"
  echo -e "${DIM}Service-onboarding golden path on CNOE idpbuilder${RESET}"
  echo "──────────────────────────────────────────────────"

  print_step "Checking prerequisites"                                 "instant"
  check_prereqs

  print_step "Creating kind cluster — idpbuilder (ArgoCD + Gitea)"   "3–6 min"
  create_cluster

  print_step "Patching ArgoCD to serve plain HTTP"                    "30 s"
  patch_argocd_insecure

  # Re-apply DNS + CA now that the cluster/context definitely exist. create_cluster
  # already healed the node early (while idpbuilder was still bootstrapping); this
  # second pass is idempotent and mainly ensures CoreDNS is patched on the right
  # context and the node CA is confirmed. No-op on a clean network.
  print_step "Re-applying DNS fix (auto-discovered resolver → CoreDNS + kind nodes)"   "10 s"
  fix_node_dns

  print_step "Re-confirming proxy CA (Zscaler / corporate SSL)"       "30 s"
  inject_proxy_ca || warn "CA injection failed — continuing; image pulls may fail behind a proxy."

  print_step "Installing Crossplane 2.4.0"                           "1 min"
  install_crossplane

  print_step "Waiting for Crossplane to be healthy"                   "30 s"
  wait_for_crossplane

  print_step "Patching Crossplane pod CA trust (SSL_CERT_DIR)"               "30 s"
  patch_crossplane_ca

  print_step "Installing provider-kubernetes + function-patch-and-transform" "2 min"
  install_providers

  print_step "Binding cluster-admin RBAC for provider-kubernetes"     "instant"
  bind_provider_rbac

  print_step "Creating downstream-system namespaces (security/SRE/reporting)" "instant"
  create_platform_namespaces

  print_step "Installing Crossview (Crossplane resource browser)"     "2 min"
  install_crossview

  print_step "Installing Backstage (developer self-service portal)"   "3 min"
  install_backstage

  print_step "Seeding example 'existing service' repos into Gitea"    "20 s"
  "${SCRIPT_DIR}/seed-example-repos.sh" || warn "Example-repo seeding failed — onboard-existing.sh will seed on demand."

  local total=$(( $(date +%s) - SCRIPT_START ))
  echo -e "\n${BOLD}${GREEN}✓ start.sh complete in $(( total / 60 ))m $(( total % 60 ))s${RESET}"

  print_cheatsheet
}

main "$@"
