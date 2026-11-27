#!/usr/bin/env bash
# show-registrations.sh — the downstream systems the platform registered the
# service with automatically: security scanning, SRE on-call, and reporting.
#
# These are now PLATFORM-OWNED, TYPED CRDs (platform.lockhead.cloud), not
# ConfigMaps — schema-validated records that are the seam for a future controller
# calling the real scanner / PagerDuty / registry. Developers never see them.
#
# Usage:  ./demo/show-registrations.sh <service-name>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../instance.env"  # per-instance name + ports
NAME="${1:-checkout}"

GREEN='\033[0;32m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
hdr() { echo -e "\n${BOLD}$*${RESET}"; }

kubectl config use-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true

echo -e "${BOLD}Downstream registrations for '${NAME}'${RESET}"
echo -e "${DIM}The developer picked a tier. The platform decided the rest — as typed CRDs it owns.${RESET}"
echo "──────────────────────────────────────────────────"

hdr "Everything the platform registered (one label, all systems)"
echo -e "${DIM}kubectl get securityscans,oncallregistrations,reportingentries -A -l lockhead.cloud/service=${NAME}${RESET}"
kubectl get securityscans,oncallregistrations,reportingentries -A \
  -l "lockhead.cloud/service=${NAME}" 2>/dev/null \
  || echo "  (no registrations found — did onboarding run?)"

hdr "1. Security scanning  (SecurityScan — cadence set by tier)"
echo -e "${DIM}kubectl get securityscan scan-${NAME} -n security-system${RESET}"
kubectl get securityscan "scan-${NAME}" -n security-system 2>/dev/null \
  || echo "  (not found)"
kubectl get securityscan "scan-${NAME}" -n security-system -o jsonpath='{.spec}' 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || true

hdr "2. SRE on-call  (OnCallRegistration — paging + SLO set by tier)"
echo -e "${DIM}kubectl get oncallregistration oncall-${NAME} -n sre-system${RESET}"
kubectl get oncallregistration "oncall-${NAME}" -n sre-system 2>/dev/null \
  || echo "  (not found)"
kubectl get oncallregistration "oncall-${NAME}" -n sre-system -o jsonpath='{.spec}' 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || true

hdr "3. Central service registry  (ReportingEntry)"
echo -e "${DIM}kubectl get reportingentry report-${NAME} -n platform-reporting${RESET}"
kubectl get reportingentry "report-${NAME}" -n platform-reporting 2>/dev/null \
  || echo "  (not found)"
kubectl get reportingentry "report-${NAME}" -n platform-reporting -o jsonpath='{.spec}' 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || true

echo ""
echo -e "${BOLD}Talking point:${RESET} the developer never opened a ticket with security or SRE."
echo "The Service CR fanned out into three TYPED, platform-owned records — same shape,"
echo "every time. Each is the seam for a controller that calls the real system next."
