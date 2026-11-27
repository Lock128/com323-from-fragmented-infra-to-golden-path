#!/usr/bin/env bash
# Health check for the re:Invent 2026 local demo environment.
# Run at any point to see what's installed, what's broken, and what's missing.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance.env"  # per-instance name + ports

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

section() { echo -e "\n${BOLD}${CYAN}── $* ${RESET}${DIM}──────────────────────────────────────────────────${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
info()    { echo -e "  ${DIM}$*${RESET}"; }

ISSUES=0
issue() { fail "$*"; (( ISSUES++ )) || true; }

# ─── 1. kubectl context ────────────────────────────────────────────────────────
section "kubectl context"
current_ctx=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "${current_ctx}" == "${KUBE_CONTEXT}" ]]; then
  ok "context: ${current_ctx}"
else
  issue "context is '${current_ctx}', expected '${KUBE_CONTEXT}'"
  info "fix: kubectl config use-context ${KUBE_CONTEXT}"
fi

# ─── 2. Cluster nodes ─────────────────────────────────────────────────────────
section "Cluster nodes"
kubectl get nodes -o wide 2>/dev/null || issue "could not reach cluster"

# ─── 3. idpbuilder namespaces (baseline) ──────────────────────────────────────
section "idpbuilder baseline namespaces"
# These are created by 'idpbuilder create'. If any are missing the bootstrap failed.
for ns in argocd gitea ingress-nginx; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    ok "namespace ${ns}"
  else
    issue "namespace ${ns} missing — idpbuilder may not have completed"
  fi
done

# ─── 3b. ArgoCD core pods ────────────────────────────────────────────────────
section "ArgoCD core pods (idpbuilder baseline)"
# idpbuilder's ArgoCD depends on a redis pod. If redis failed its image pull
# (common behind a proxy), it never creates the 'argocd-redis' Secret, causing
# argocd-server, argocd-repo-server, and argocd-application-controller to all
# fail with "secret argocd-redis not found".
for deploy in argocd-redis argocd-server argocd-repo-server; do
  pod_status=$(kubectl get pods -n argocd -l "app.kubernetes.io/name=${deploy}" \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "${pod_status}" == "Running" ]]; then
    ok "${deploy}: Running"
  elif [[ -z "${pod_status}" ]]; then
    issue "${deploy}: no pod found"
    info "fix: kubectl rollout restart deployment/${deploy} -n argocd"
  else
    issue "${deploy}: ${pod_status}"
    info "Likely cause: image pull failure (proxy/DNS) or missing argocd-redis Secret"
    info "fix: kubectl rollout restart deployment/argocd-redis -n argocd"
    info "     (redis must start first to create the argocd-redis Secret)"
  fi
done

# ─── 4. Crossplane installation ───────────────────────────────────────────────
section "Crossplane (crossplane-system)"
if ! kubectl get namespace crossplane-system >/dev/null 2>&1; then
  issue "crossplane-system namespace missing — Crossplane not installed"
  info "fix: helm upgrade --install crossplane crossplane-stable/crossplane \\"
  info "       --namespace crossplane-system --create-namespace --version 2.4.0 \\"
  info "       --set args='{--enable-usages}' --wait --timeout 5m"
else
  ok "namespace crossplane-system exists"

  # Check each Crossplane pod
  echo ""
  info "Pods:"
  kubectl get pods -n crossplane-system \
    --no-headers 2>/dev/null | while read -r name ready status restarts age; do
    if [[ "${status}" == "Running" ]]; then
      ok "  ${name}  (${status}, restarts: ${restarts})"
    else
      issue "  ${name}  status=${status} ready=${ready} restarts=${restarts}"
      info "  diagnose: kubectl describe pod ${name} -n crossplane-system"
    fi
  done

  # Helm release version
  echo ""
  info "Helm release:"
  helm list -n crossplane-system 2>/dev/null || warn "helm list failed"
fi

# ─── 5. Crossplane provider ───────────────────────────────────────────────────
section "provider-kubernetes"
# In Crossplane 2.x the Provider object API path can differ from 1.x.
# Check the Provider object first; if not found, fall back to checking whether
# the provider runtime pod is actually running — a running pod means the package
# manager installed the provider even if the CRD path has changed.
provider_obj_found=false
if kubectl get provider provider-kubernetes >/dev/null 2>&1; then
  provider_obj_found=true
elif kubectl get providers.pkg.crossplane.io provider-kubernetes >/dev/null 2>&1; then
  provider_obj_found=true
fi

if ${provider_obj_found}; then
  installed=$(kubectl get provider provider-kubernetes \
    -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null || \
    kubectl get providers.pkg.crossplane.io provider-kubernetes \
    -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
  healthy=$(kubectl get provider provider-kubernetes \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || \
    kubectl get providers.pkg.crossplane.io provider-kubernetes \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null)

  [[ "${installed}" == "True" ]] && ok "Installed=True" || issue "Installed=${installed:-Unknown}"
  [[ "${healthy}"   == "True" ]] && ok "Healthy=True"   || issue "Healthy=${healthy:-Unknown}"

  if [[ "${healthy}" != "True" ]]; then
    info "diagnose: kubectl describe provider provider-kubernetes"
    info "ImagePullBackOff causes:"
    info "  • wrong image tag  → kubectl describe provider provider-kubernetes | grep image"
    info "  • x509/TLS error   → Zscaler proxy; run inject_proxy_ca from start.sh and delete pods"
    info "  • rate limit       → docker login or wait and retry"
  fi
else
  # No Provider object — check if the runtime pod is running anyway (Crossplane 2.x quirk)
  provider_pod=$(kubectl get pods -n crossplane-system --no-headers 2>/dev/null | \
    awk '{print $1}' | grep "^provider-kubernetes" | head -1)
  if [[ -n "${provider_pod}" ]]; then
    pod_status=$(kubectl get pod "${provider_pod}" -n crossplane-system \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "${pod_status}" == "Running" ]]; then
      warn "Provider object not found via CRD, but pod '${provider_pod}' is Running"
      info "Crossplane 2.x may use a different API path — provider appears functional"
      info "Verify: kubectl get pods -n crossplane-system | grep provider-kubernetes"
    else
      issue "provider-kubernetes pod found but status=${pod_status}"
      info "fix: kubectl apply -f packages/1-crossplane/providers.yaml"
    fi
  else
    issue "provider-kubernetes not found (no object and no pod)"
    info "fix: kubectl apply -f packages/1-crossplane/providers.yaml"
  fi
fi

# ─── 6. Crossplane function ───────────────────────────────────────────────────
section "function-patch-and-transform"
if ! kubectl get function function-patch-and-transform >/dev/null 2>&1; then
  issue "function-patch-and-transform not found"
  info "fix: kubectl apply -f packages/1-crossplane/functions.yaml"
else
  installed=$(kubectl get function function-patch-and-transform \
    -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
  healthy=$(kubectl get function function-patch-and-transform \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null)

  [[ "${installed}" == "True" ]] && ok "Installed=True" || issue "Installed=${installed:-Unknown}"
  [[ "${healthy}"   == "True" ]] && ok "Healthy=True"   || issue "Healthy=${healthy:-Unknown}"

  [[ "${healthy}" != "True" ]] && info "diagnose: kubectl describe function function-patch-and-transform"
fi

# ─── 7. ProviderConfig ────────────────────────────────────────────────────────
section "ProviderConfig (in-cluster)"
if kubectl get providerconfig in-cluster >/dev/null 2>&1; then
  ok "ProviderConfig 'in-cluster' exists"
else
  issue "ProviderConfig 'in-cluster' missing"
  info "fix: kubectl apply -f packages/1-crossplane/providerconfig.yaml"
fi

# ─── 8. RBAC for provider-kubernetes ─────────────────────────────────────────
section "RBAC (provider-kubernetes cluster-admin binding)"
if kubectl get clusterrolebinding crossplane-provider-kubernetes-admin >/dev/null 2>&1; then
  ok "ClusterRoleBinding crossplane-provider-kubernetes-admin exists"
else
  issue "ClusterRoleBinding missing — provider-kubernetes cannot create resources"
  info "fix: re-run bind_provider_rbac from start.sh, or:"
  info "     SA=\$(kubectl get sa -n crossplane-system -o name | grep provider-kubernetes | head -1 | cut -d/ -f2)"
  info "     kubectl create clusterrolebinding crossplane-provider-kubernetes-admin \\"
  info "       --clusterrole=cluster-admin --serviceaccount=crossplane-system:\${SA}"
fi

# ─── 9. XRDs ──────────────────────────────────────────────────────────────────
section "XRD (platform API — Service)"
for xrd in \
  xservices.lockhead.cloud; do
  if ! kubectl get xrd "${xrd}" >/dev/null 2>&1; then
    issue "XRD ${xrd} missing"
    info "fix: ./setup_gitops.sh  (or ./setup_direct.sh)"
  else
    established=$(kubectl get xrd "${xrd}" \
      -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
    [[ "${established}" == "True" ]] \
      && ok "${xrd}" \
      || issue "${xrd}  Established=${established:-Unknown}"
  fi
done

# ─── 10. Composition ──────────────────────────────────────────────────────────
section "Composition"
for comp in \
  service-onboarding; do
  if kubectl get composition "${comp}" >/dev/null 2>&1; then
    ok "${comp}"
  else
    issue "${comp} missing"
    info "fix: ./setup_gitops.sh  (or ./setup_direct.sh)"
  fi
done

# ─── 11. Downstream-system namespaces ─────────────────────────────────────────
section "Downstream-system namespaces (registration targets)"
for ns in security-system sre-system platform-reporting; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    ok "namespace ${ns} exists"
  else
    issue "namespace ${ns} missing (service registrations will fail)"
    info "fix: kubectl create namespace ${ns}"
  fi
done
# The team namespace is created on demand during onboarding.
if kubectl get namespace team-storefront >/dev/null 2>&1; then
  ok "namespace team-storefront exists (demo team)"
else
  info "team-storefront not present yet — created when you onboard a service."
fi

# ─── 12. DNS resolution (kind nodes) ─────────────────────────────────────────
section "DNS resolution inside kind nodes"
# Docker Desktop's internal DNS can be blocked on some corporate / VPN networks,
# and Google DNS (8.8.8.8) is itself blocked on others — so there is no single
# "correct" resolver IP. What matters is whether name resolution actually works.
# We check two levels by *functionally testing resolution*, not by matching an IP:
#   a) CoreDNS upstream — report whatever it forwards to (informational)
#   b) Node resolv.conf — can the node actually resolve a real registry host?
#      (this is what containerd uses for image pulls)

# a) CoreDNS upstream (informational — any reachable resolver is fine)
coredns_forward=$(kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -E "^[[:space:]]*forward" | xargs || true)
if [[ -n "${coredns_forward}" ]]; then
  ok "CoreDNS upstream: ${coredns_forward}"
else
  warn "CoreDNS upstream not set — in-cluster DNS may be misconfigured"
  info "fix: see fix_node_dns in start.sh, then: kubectl rollout restart deployment/coredns -n kube-system"
fi

# b) Node resolv.conf — functionally verify the node can resolve a registry host.
# A working resolver (whatever its IP) means containerd image pulls will succeed.
nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=${DEMO_NAME}" --format "{{.Names}}" 2>/dev/null) || nodes=""
if [[ -z "${nodes}" ]]; then
  warn "Could not list kind nodes — skipping node DNS check"
else
  for node in ${nodes}; do
    node_ns=$(docker exec "${node}" cat /etc/resolv.conf 2>/dev/null | \
      awk '/^nameserver/{print $2}' | tr '\n' ' ' | xargs)
    if docker exec "${node}" bash -c 'timeout 5 getent ahosts quay.io >/dev/null 2>&1'; then
      ok "node ${node} DNS works (resolvers: ${node_ns:-unknown})"
    else
      issue "node ${node} cannot resolve quay.io (resolvers: '${node_ns}') — image pulls will fail"
      info "Symptom: ErrImagePull with 'i/o timeout' or 'server misbehaving' in events"
      info "fix: re-run ./start.sh (fix_node_dns points nodes at a working resolver),"
      info "     or override the resolver: DNS_SERVERS='8.8.8.8 8.8.4.4' ./start.sh"
      info "     then: kubectl delete pods -n crossplane-system --all; kubectl delete pods -n argocd --all"
    fi
  done
fi

# ─── 13. Proxy / TLS check ────────────────────────────────────────────────────
section "Proxy CA trust (xpkg.upbound.io)"
# Test TLS from the host — a failure here means image pulls will fail from kind nodes too.
if curl --silent --max-time 5 https://xpkg.upbound.io/v2/ >/dev/null 2>&1; then
  ok "xpkg.upbound.io reachable and TLS trusted from host"
else
  warn "xpkg.upbound.io TLS check failed from host"
  info "If behind Zscaler: the CA is probably not injected into kind nodes."
  info "fix: run inject_proxy_ca section from start.sh, then:"
  info "     kubectl delete pods -n crossplane-system --all"
fi

# ─── 14. Onboarded services ───────────────────────────────────────────────────
section "Onboarded services (golden-path output)"

# 14a. Service claims
svc_count=$(kubectl get services.lockhead.cloud -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${svc_count}" -gt 0 ]]; then
  ok "${svc_count} Service claim(s) present:"
  kubectl get services.lockhead.cloud -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TEAM:.spec.team,TIER:.spec.tier,ARGO:.status.argoApplication' \
    --no-headers 2>/dev/null | while read -r line; do ok "  ${line}"; done || true
else
  info "No services onboarded yet — run ./demo/onboard-service.sh checkout storefront"
fi

# 14b. Argo CD Applications the composition created for services
echo ""
info "Argo CD Applications for onboarded services:"
kubectl get application -n argocd -l lockhead.cloud/managed-by=crossplane \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --no-headers 2>/dev/null | while read -r line; do ok "  ${line}"; done || true
if ! kubectl get application -n argocd -l lockhead.cloud/managed-by=crossplane --no-headers 2>/dev/null | grep -q .; then
  info "(none yet)"
fi

# 14c. Downstream registrations (security / SRE / reporting)
echo ""
info "Downstream registrations created by the platform (platform-owned CRDs):"
# kind : label pairs — the registrations are now typed CRs, not ConfigMaps.
for pair in "securityscans:security-scan" "oncallregistrations:sre-oncall" "reportingentries:reporting"; do
  kind="${pair%%:*}"; reg="${pair##*:}"
  n=$(kubectl get "${kind}" -A -l "lockhead.cloud/registration=${reg}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${n}" -gt 0 ]]; then
    ok "  ${reg} (${kind}): ${n} registration(s)"
  else
    info "  ${reg} (${kind}): none yet"
  fi
done

# ─── 14b. Crossview (Crossplane UI) ──────────────────────────────────────────
section "Crossview (Crossplane resource browser)"
cv_pod=$(kubectl get pods -n crossview-system --no-headers 2>/dev/null | \
  grep -v postgres | awk '{print $3}' | head -1)
if [[ "${cv_pod}" == "Running" ]]; then
  ok "Crossview pod: Running"
  info "Access: kubectl port-forward -n crossview-system svc/crossview-service ${CROSSVIEW_PORT}:80"
  info "         → http://localhost:${CROSSVIEW_PORT}  (no login)"
  info "Or run: ./ui.sh"
elif [[ -z "${cv_pod}" ]]; then
  warn "Crossview not installed (no pods in crossview-system)"
  info "Install: helm upgrade --install crossview crossview/crossview \\"
  info "           --namespace crossview-system --create-namespace \\"
  info "           --set config.server.auth.mode=none \\"
  info "           --set secrets.dbPassword=crossview-demo \\"
  info "           \"--set secrets.sessionSecret=\$(openssl rand -base64 32)\" \\"
  info "           --wait"
else
  issue "Crossview pod status: ${cv_pod}"
  info "diagnose: kubectl describe pods -n crossview-system"
fi

# ─── 16. Backstage ────────────────────────────────────────────────────────────
section "Backstage (developer self-service portal)"
bs_deploy=$(kubectl get deployment backstage -n backstage \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
if [[ "${bs_deploy}" == "True" ]]; then
  ok "Backstage deployment: Available"
  info "Access: ./ui.sh  →  http://localhost:${BACKSTAGE_PORT}"
  info "Template appears ~1 min after setup_gitops.sh / setup_direct.sh pushes the catalog."
elif [[ -z "${bs_deploy}" ]]; then
  issue "Backstage not installed (no deployment in backstage namespace)"
  info "Install: run ./start.sh — install_backstage() is step 15"
  info "     or: re-run start.sh on existing cluster (it's idempotent)"
else
  # Deployed but not yet available — check pod status
  bs_pod_status=$(kubectl get pods -n backstage -l app=backstage \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "${bs_pod_status}" == "Running" ]]; then
    warn "Backstage pod Running but deployment not yet Available (startup in progress)"
    info "Backstage startup takes ~60 s — wait and re-run check_health.sh"
  elif [[ "${bs_pod_status}" == "Init:0/1" || "${bs_pod_status}" == "ContainerCreating" ]]; then
    warn "Backstage pod is pulling image from ghcr.io — this may take a minute behind a proxy"
    info "Watch: kubectl get pods -n backstage -w"
  elif [[ "${bs_pod_status}" == "CreateContainerConfigError" ]]; then
    issue "Backstage pod: CreateContainerConfigError — a required Secret is missing"
    info "diagnose: kubectl describe pod -n backstage -l app=backstage"
    info "Expected secrets in backstage namespace: backstage-env-vars, gitea-credentials"
    info "fix: re-run ./start.sh  (install_backstage creates these secrets first)"
  else
    issue "Backstage pod status: ${bs_pod_status:-Unknown}"
    info "diagnose: kubectl describe pod -n backstage -l app=backstage"
    info "          kubectl logs -n backstage deploy/backstage --tail=30"
  fi
fi

# Check Dex OIDC provider (Backstage login)
dex_status=$(kubectl get deployment dex -n backstage \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
if [[ "${dex_status}" == "True" ]]; then
  ok "Dex OIDC deployment: Available  (sign in: demo@example.com / password)"
elif [[ -z "${dex_status}" ]]; then
  issue "Dex OIDC not installed — Backstage sign-in will fail"
  info "fix: kubectl apply -f packages/5-backstage/install.yaml && kubectl rollout restart deployment/backstage -n backstage"
else
  warn "Dex OIDC not yet Available (${dex_status}) — Backstage sign-in may fail"
  info "diagnose: kubectl logs -n backstage deploy/dex --tail=20"
fi

# Check PostgreSQL (Backstage's database)
pg_pod=$(kubectl get pods -n backstage -l app=postgresql \
  --no-headers 2>/dev/null | awk '{print $3}' | head -1)
if [[ "${pg_pod}" == "Running" ]]; then
  ok "backstage/postgresql pod: Running"
elif [[ -z "${pg_pod}" ]]; then
  issue "backstage/postgresql pod not found — Backstage cannot start without its database"
  info "fix: re-run ./start.sh"
else
  issue "backstage/postgresql pod status: ${pg_pod}"
  info "diagnose: kubectl describe pod -n backstage -l app=postgresql"
fi

# Check catalog template is available (platform-api repo has catalog-info.yaml)
if kubectl get secret -n gitea gitea-credential >/dev/null 2>&1; then
  gitea_pass=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)
  catalog_http=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "giteaAdmin:${gitea_pass}" \
    "http://localhost:${GITEA_PORT}/giteaAdmin/platform-api/raw/branch/main/catalog-info.yaml" \
    --max-time 3 2>/dev/null || echo "000")
  if [[ "${catalog_http}" == "200" ]]; then
    ok "Backstage catalog in Gitea platform-api: found"
  elif [[ "${catalog_http}" == "404" || "${catalog_http}" == "000" ]]; then
    warn "Backstage catalog not yet in Gitea (HTTP ${catalog_http})"
    info "Run ./setup_gitops.sh or ./setup_direct.sh to push the catalog."
    info "Backstage will pick it up automatically within ~1 minute."
  else
    warn "Backstage catalog check: unexpected HTTP ${catalog_http}"
  fi
fi

# ─── 17. Recent failure events (last 5 minutes) ───────────────────────────────
section "Recent failure events — last 5 minutes (all namespaces)"
# Only show events from the last 5 minutes so resolved issues don't keep showing
# up as noise. Old events with large LAST SEEN values are stale and not actionable.
now_epoch=$(date +%s)
cutoff=$(( now_epoch - 300 ))  # 5 minutes ago

# Get all Failed events with timestamps, filter to recent ones only
kubectl get events -A \
  --field-selector reason=Failed \
  --sort-by='.lastTimestamp' \
  -o custom-columns=\
'NAMESPACE:.metadata.namespace,LAST_SEEN:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  2>/dev/null | awk -v cutoff="${cutoff}" '
NR==1 { print; next }
{
  # Parse the LAST_SEEN timestamp (format: 2026-09-14T10:05:00Z or similar)
  ts = $2
  # Use date to convert — if it fails, print anyway (better noisy than silent)
  cmd = "date -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"" ts "\" \"+%s\" 2>/dev/null || echo 0"
  cmd | getline epoch
  close(cmd)
  if (epoch + 0 >= cutoff + 0) print
}' || \
  # Fallback if awk date parsing fails: just show raw events with a note
  kubectl get events -A --field-selector reason=Failed \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -10

echo ""
info "Events older than 5 minutes are hidden — they are likely already resolved."
info "To see all events: kubectl get events -A --field-selector reason=Failed --sort-by='.lastTimestamp'"

# ─── summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ "${ISSUES}" -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}All checks passed — environment looks healthy.${RESET}"
else
  echo -e "${BOLD}${RED}${ISSUES} issue(s) found. See ✗ lines above for fixes.${RESET}"
fi
echo ""
