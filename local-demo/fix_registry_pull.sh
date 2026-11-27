#!/usr/bin/env bash
# fix_registry_pull.sh — make the in-cluster Gitea OCI registry pullable by
# BOTH Crossplane's package manager AND the kubelet/containerd runtime.
#
# WHY THIS EXISTS
#   Gitea's in-cluster registry (my-gitea-http:3000) is plain HTTP. Crossplane
#   v2.4.0's package manager has no "insecure registry" flag — it always speaks
#   HTTPS to a non-localhost host, so a direct HTTP ref fails with
#     "http: server gave HTTP response to HTTPS client".
#   And the Go composition function (packages/4-observability) ships a RUNTIME
#   image that the kubelet pulls via containerd — a second, node-level path.
#
#   The fix is to pull over idpbuilder's HTTPS ingress (gitea.cnoe.localtest.me,
#   served by ingress-nginx with the cnoe.io CA) on BOTH paths:
#
#     1. CoreDNS: resolve gitea.cnoe.localtest.me -> the ingress-nginx ClusterIP
#        (it otherwise resolves to 127.0.0.1, useless in-cluster). This is what
#        Crossplane's package manager uses.
#     2. Crossplane trust: add the idpbuilder CA (cnoe.io) to the zscaler-ca
#        ConfigMap already mounted at /etc/ssl/custom-ca, then restart crossplane.
#     3. Pull secret: gitea-registry-creds in crossplane-system — the registry
#        needs auth even for the public "lockhead" org. The Function references it.
#     4. containerd (node): the kubelet pulls the runtime image. Point a
#        certs.d mirror for gitea.cnoe.localtest.me at the ingress-nginx HTTPS
#        NodePort (reachable from the node, SNI preserved via /etc/hosts),
#        skip_verify=true.
#
# Idempotent. Safe to re-run. Called by setup_gitops.sh; build.sh also calls it
# so a fresh push + install works in one go.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }

KCTX="${KUBE_CONTEXT}"
NODE="${DEMO_NAME}-control-plane"
INGRESS_HOST="gitea.cnoe.localtest.me"
k() { kubectl --context "${KCTX}" "$@"; }

# ── 1. CoreDNS: resolve the ingress host to the ingress-nginx ClusterIP ──────
fix_coredns() {
  local nginx_ip
  nginx_ip=$(k -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
  [[ -z "${nginx_ip}" ]] && { warn "ingress-nginx-controller not found — skipping CoreDNS fix."; return 0; }

  local cur
  cur=$(k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
  if echo "${cur}" | grep -q "${nginx_ip} ${INGRESS_HOST}"; then
    info "CoreDNS already maps ${INGRESS_HOST} -> ${nginx_ip} — skipping."
    return 0
  fi

  info "Patching CoreDNS: ${INGRESS_HOST} -> ${nginx_ip} (ingress-nginx)..."
  # Insert a hosts{} block right after the 'ready' line. Strip any stale block first.
  local new
  new=$(echo "${cur}" \
    | sed '/[0-9.]* '"${INGRESS_HOST}"'/d' \
    | awk -v ip="${nginx_ip}" -v host="${INGRESS_HOST}" '
        /^[[:space:]]*ready[[:space:]]*$/ {
          print; print "    hosts {"; print "       " ip " " host; print "       fallthrough"; print "    }"; next
        } { print }')
  k -n kube-system create cm coredns --from-literal=Corefile="${new}" \
    --dry-run=client -o yaml | k -n kube-system apply -f - >/dev/null
  k -n kube-system rollout restart deploy/coredns >/dev/null
  k -n kube-system rollout status deploy/coredns --timeout=60s >/dev/null
  success "CoreDNS updated."
}

# ── 2. Crossplane trust: add the idpbuilder CA to the mounted CA bundle ──────
fix_crossplane_ca() {
  if ! k -n crossplane-system get cm zscaler-ca >/dev/null 2>&1; then
    # No proxy-CA ConfigMap yet (non-proxy env): create one with just the idp CA.
    info "Creating zscaler-ca ConfigMap with the idpbuilder CA..."
    local tmp; tmp=$(mktemp)
    k get secret idpbuilder-cert -n default -o jsonpath='{.data.ca\.crt}' | base64 -d > "${tmp}"
    k -n crossplane-system create cm zscaler-ca --from-file=idpbuilder-ca.crt="${tmp}" \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    rm -f "${tmp}"
  elif k -n crossplane-system get cm zscaler-ca -o jsonpath='{.data.idpbuilder-ca\.crt}' 2>/dev/null | grep -q "CERTIFICATE"; then
    info "Crossplane already trusts the idpbuilder CA — skipping."
  else
    info "Adding the idpbuilder CA to crossplane's trust bundle..."
    local tmp; tmp=$(mktemp)
    k get secret idpbuilder-cert -n default -o jsonpath='{.data.ca\.crt}' | base64 -d > "${tmp}"
    k -n crossplane-system get cm zscaler-ca -o json \
      | python3 -c "import json,sys; cm=json.load(sys.stdin); cm['data']['idpbuilder-ca.crt']=open('${tmp}').read(); print(json.dumps({'data':cm['data']}))" \
      | k -n crossplane-system patch cm zscaler-ca --type=merge --patch-file=/dev/stdin >/dev/null
    rm -f "${tmp}"
  fi

  # Ensure the mount + SSL_CERT_DIR exist (start.sh usually sets these for the proxy).
  if ! k -n crossplane-system get deploy crossplane \
      -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -q "SSL_CERT_DIR"; then
    info "Wiring the CA bundle into the crossplane deployment..."
    k -n crossplane-system patch deployment crossplane --type=strategic --patch='{
      "spec":{"template":{"spec":{
        "volumes":[{"name":"zscaler-ca","configMap":{"name":"zscaler-ca"}}],
        "containers":[{"name":"crossplane",
          "env":[{"name":"SSL_CERT_DIR","value":"/etc/ssl/certs:/etc/ssl/custom-ca"}],
          "volumeMounts":[{"name":"zscaler-ca","mountPath":"/etc/ssl/custom-ca","readOnly":true}]
        }]
      }}}}' >/dev/null
  fi
  # Restart so Go re-reads the cert dir (cert pool is loaded at process start).
  k -n crossplane-system rollout restart deploy/crossplane >/dev/null
  k -n crossplane-system rollout status deploy/crossplane --timeout=120s >/dev/null
  success "Crossplane trusts the idpbuilder CA."
}

# ── 3. Pull secret for the Function (registry needs auth) ────────────────────
fix_pull_secret() {
  local pw
  pw=$(k -n gitea get secret gitea-credential -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
  [[ -z "${pw}" ]] && { warn "No Gitea password — skipping pull secret."; return 0; }
  info "Creating the gitea-registry-creds pull secret (crossplane-system)..."
  k create secret docker-registry gitea-registry-creds -n crossplane-system \
    --docker-server="${INGRESS_HOST}" \
    --docker-username=giteaAdmin \
    --docker-password="${pw}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  success "Pull secret ready."
}

# ── 4. containerd (node): mirror the ingress host to the nginx HTTPS NodePort ─
fix_containerd() {
  local np
  np=$(k -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
  [[ -z "${np}" ]] && { warn "Could not find the ingress-nginx 443 NodePort — skipping containerd fix."; return 0; }

  if ! docker ps --format '{{.Names}}' | grep -q "^${NODE}$"; then
    warn "kind node ${NODE} not found via docker — skipping containerd fix."
    return 0
  fi

  info "Configuring containerd on ${NODE} to pull ${INGRESS_HOST} via NodePort ${np}..."
  # /etc/hosts so the ingress host resolves to the node's own NodePort, keeping
  # the SNI/Host = gitea.cnoe.localtest.me (nginx routes by SNI to Gitea).
  docker exec "${NODE}" sh -c "grep -q '${INGRESS_HOST}' /etc/hosts || echo '127.0.0.1 ${INGRESS_HOST}' >> /etc/hosts"
  docker exec "${NODE}" sh -c "mkdir -p '/etc/containerd/certs.d/${INGRESS_HOST}'"
  docker exec "${NODE}" sh -c "cat > '/etc/containerd/certs.d/${INGRESS_HOST}/hosts.toml' <<EOF
server = \"https://${INGRESS_HOST}\"
[host.\"https://${INGRESS_HOST}:${np}\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF"
  docker exec "${NODE}" sh -c 'systemctl restart containerd' 2>/dev/null \
    || docker exec "${NODE}" sh -c 'kill -s HUP $(cat /run/containerd/containerd.pid)' 2>/dev/null || true
  sleep 4
  success "containerd configured (node can pull the Function runtime image)."
}

main() {
  echo "── Registry pull fix (Crossplane + containerd → Gitea via HTTPS ingress) ──"
  fix_coredns
  fix_crossplane_ca
  fix_pull_secret
  fix_containerd
  success "Registry pull fix applied."
}

main "$@"
