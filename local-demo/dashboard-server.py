#!/usr/bin/env python3
"""
dashboard-server.py — a tiny LOCALHOST-ONLY backend so the demo dashboard can
trigger the demo steps (and run read-only kubectl) from the browser.

WHY THIS EXISTS
---------------
The dashboard talks to the cluster through `kubectl proxy` (K8s API only). The
onboarding / add-finops / change-tier steps also push to Gitea and run scripts —
which a static page can't do. This server exposes a SMALL, ALLOWLISTED HTTP API
that the dashboard calls to run those exact demo scripts and stream the output.

SECURITY (read this)
--------------------
* Binds to 127.0.0.1 ONLY. Never expose it. It runs shell commands on your box.
* Browser requests are only accepted from pages on http://localhost or
  http://127.0.0.1 (Origin check, CORS limited to those origins), and only for
  Host localhost:<port> / 127.0.0.1:<port> (blocks DNS rebinding). Other
  websites open in the same browser get 403.
* Only an explicit ALLOWLIST of actions can run (the demo scripts), with their
  args validated against a strict pattern. There is no "run arbitrary shell".
* The kubectl box is restricted to READ verbs by default (get/describe/
  explain/api-resources/version/top/logs). Set DASH_ALLOW_KUBECTL_WRITE=1 to
  also allow apply/patch/delete/etc. if you really want it.
* Intended for a local, single-user demo cluster you control. Do not ship it.

RUN
---
  ./dashboard-server.py            # listens on 127.0.0.1:8012
  PORT=8012 ./dashboard-server.py  # override port
(ui.sh starts it automatically.)
"""
import json
import os
import re
import shlex
import subprocess
import threading
import atexit
import tempfile
import time
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Strip ANSI escape sequences (color codes like \033[1m, \033[0;32m) so the
# browser <pre> shows clean text instead of raw "[1m…[0m" noise. The demo
# scripts emit colored terminal output; the browser can't interpret it.
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s):
    return ANSI_RE.sub("", s)

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("PORT") or os.environ.get("CTL_PORT") or "8112")  # instance.env: CTL_PORT
# The cluster the dashboard's own kubectl calls use (the demo scripts read the same variable).
KUBE_CONTEXT = os.environ.get("KUBE_CONTEXT") or "kind-" + os.environ.get("DEMO_NAME", "com323")
# Local port used when a port-forward to an onboarded app is requested without one (instance.env: APP_PORT).
APP_PORT = os.environ.get("APP_PORT", "8180")
# Ingress port of this cluster (instance.env: IDP_PORT), shown in the build-app preview.
IDP_PORT = os.environ.get("IDP_PORT", "8643")
ALLOW_KUBECTL_WRITE = os.environ.get("DASH_ALLOW_KUBECTL_WRITE", "") == "1"
# Actions that cannot run on this cluster (e.g. build-app and add-observability on EKS,
# which need the kind-only Gitea HTTPS ingress). Comma-separated. DASH_DISABLED_REASON
# is shown to the user instead of running anything.
DISABLED_ACTIONS = {a.strip() for a in os.environ.get("DASH_DISABLED_ACTIONS", "").split(",") if a.strip()}
DISABLED_REASON = os.environ.get("DASH_DISABLED_REASON", "This action is not available on this cluster.")

# ── validation helpers ───────────────────────────────────────────────────────
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")      # service / team names
TIER_RE = re.compile(r"^(experimental|standard|critical)$")
LANG_RE = re.compile(r"^(go|node|python|php)$")


def _name(v, default=None):
    v = (v or default or "").strip()
    if not NAME_RE.match(v):
        raise ValueError(f"invalid name '{v}' (lowercase letters/digits/hyphens)")
    return v


# ── action allowlist ─────────────────────────────────────────────────────────
# Each action returns the argv list to run. Args come from the request body and
# are validated. The command is ALWAYS one of our own scripts — never free text.
def build_onboard(p):
    return ["./demo/onboard-service.sh", _name(p.get("name")), _name(p.get("team"), "storefront"),
            _lang(p.get("language", "go")), _tier(p.get("tier", "standard"))]


def build_onboard_existing(p):
    argv = ["./demo/onboard-existing.sh"]
    if p.get("direct"):
        argv.append("--direct")
    return argv


def build_change_tier(p):
    return ["./demo/change-tier.sh", _name(p.get("name")), _name(p.get("team"), "storefront"),
            _tier(p.get("tier", "critical"))]


def build_show_registrations(p):
    return ["./demo/show-registrations.sh", _name(p.get("name"))]


def build_show_deploy(p):
    return ["./demo/show-deploy.sh", _name(p.get("name")), _name(p.get("team"), "storefront")]


def build_show_repo(p):
    return ["./demo/show-repo.sh", _name(p.get("name"))]


def build_show_drift(p):
    return ["./demo/show-drift.sh", _name(p.get("name"))]


def _free_port():
    import socket
    with socket.socket() as sk:
        sk.bind(("127.0.0.1", 0))
        return sk.getsockname()[1]
def _port(v):
    if str(v).strip().lower() == "auto":
        return _free_port()
    try:
        n = int(str(v if v not in (None, "") else APP_PORT).strip())
    except ValueError:
        raise ValueError(f"invalid port '{v}'")
    if not 1024 <= n <= 65535:
        raise ValueError(f"port {n} is outside 1024-65535")
    return n
def build_rollout_status(p):
    return ["kubectl", "--context", KUBE_CONTEXT, "rollout", "status", f"deploy/{_name(p.get('name'))}",
            "-n", f"team-{_name(p.get('team'), 'storefront')}", "--timeout=180s"]
def build_port_forward(p):
    if str(p.get("port", "")).strip().lower() == "auto":
        p["port"] = _free_port()          # resolve once; run_background reads the same params
    port = _port(p.get("port"))
    return ["kubectl", "--context", KUBE_CONTEXT, "port-forward", "-n", f"team-{_name(p.get('team'), 'storefront')}",
            f"svc/{_name(p.get('name'))}", f"{port}:80"]
def build_port_forward_stop(p):
    return ["echo", "stop the port-forwards started from this page"]
def build_show_context(p):
    return ["./demo/show-context.sh"]
def build_list_services(p):
    return ["./demo/list-services.sh"]


# Which demo target this backend serves (set by the ui.sh that started it):
# local (kind), eks (self-managed EKS), managed (EKS Capabilities), custom.
DEMO_TARGET = os.environ.get("DEMO_TARGET", "local")
TARGET_RE = re.compile(r"^(local|eks|managed)$")


def build_start_target(p):
    t = (p.get("target") or "").strip()
    if not TARGET_RE.match(t):
        raise ValueError(f"invalid target '{t}' (local, eks or managed)")
    if t == DEMO_TARGET:
        raise ValueError(f"this page already shows the '{t}' target")
    # Starts the OTHER target's UIs on its own ports. This page and its backend keep running.
    return ["./target.sh", "start", t, "--no-open"]


def build_build_app(p):
    argv = ["./demo/build-app.sh", _name(p.get("name"))]
    tag = (p.get("tag") or "").strip()
    if tag:
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", tag):
            raise ValueError(f"invalid tag '{tag}'")
        argv.append(tag)
    return argv


def build_reset(p):
    return ["./demo/reset-service.sh", _name(p.get("name")), _name(p.get("team"), "storefront")]


def build_reset_all(p):
    argv = ["./demo/reset-all.sh"]
    if p.get("keepExtensions"):
        argv.append("--keep-extensions")
    return argv


def build_refresh_argo(p):
    return ["./demo/refresh-argo.sh"]


def build_add_finops(p):
    argv = ["./demo/add-finops.sh"]
    mode = p.get("mode")
    if mode == "consume":
        argv.append("--consume")
    elif mode == "remove":
        argv.append("--remove")
    return argv


def build_add_observability(p):
    argv = ["./demo/add-observability.sh"]
    mode = p.get("mode")
    if mode == "consume":
        argv.append("--consume")
    elif mode == "remove":
        argv.append("--remove")
    return argv


def _tier(v):
    v = (v or "").strip()
    if not TIER_RE.match(v):
        raise ValueError(f"invalid tier '{v}'")
    return v


def _lang(v):
    v = (v or "").strip()
    if not LANG_RE.match(v):
        raise ValueError(f"invalid language '{v}'")
    return v


ACTIONS = {
    "onboard-service":   build_onboard,
    "onboard-existing":  build_onboard_existing,
    "build-app":         build_build_app,
    "change-tier":       build_change_tier,
    "show-registrations": build_show_registrations,
    "show-deploy":       build_show_deploy,
    "show-repo":         build_show_repo,
    "show-drift":        build_show_drift,
    "list-services":     build_list_services,
    "show-context":      build_show_context,
    "rollout-status":    build_rollout_status,
    "port-forward":      build_port_forward,
    "port-forward-stop": build_port_forward_stop,
    "reset-service":     build_reset,
    "reset-all":         build_reset_all,
    "add-finops":        build_add_finops,
    "add-observability": build_add_observability,
    "refresh-argo":      build_refresh_argo,
    "start-target":      build_start_target,
}

# kubectl read verbs allowed in the command box.
KUBECTL_READ_VERBS = {"get", "describe", "explain", "api-resources", "api-versions",
                      "version", "top", "logs", "cluster-info", "events"}


def build_kubectl(argv_str):
    """Validate a kubectl command string from the box. Returns argv or raises."""
    parts = shlex.split(argv_str)
    if not parts:
        raise ValueError("empty command")
    if parts[0] == "kubectl":
        parts = parts[1:]
    if not parts:
        raise ValueError("no kubectl subcommand")
    verb = parts[0]
    rollout_read = verb == "rollout" and len(parts) > 1 and parts[1] in ("status", "history")
    if not ALLOW_KUBECTL_WRITE and verb not in KUBECTL_READ_VERBS and not rollout_read:
        raise ValueError(
            f"verb '{verb}' not allowed (read-only). Allowed: {', '.join(sorted(KUBECTL_READ_VERBS))}. "
            "Set DASH_ALLOW_KUBECTL_WRITE=1 to allow writes.")
    # No shell metacharacters — shlex already split; reject obvious injection.
    for tok in parts:
        if any(c in tok for c in [";", "|", "&", "`", "$(", ">", "<"]):
            raise ValueError("shell metacharacters are not allowed")
    return ["kubectl", "--context", KUBE_CONTEXT] + parts


def preview_for(action, params):
    """Return the human-readable command that WOULD run (for the confirm step)."""
    if action in DISABLED_ACTIONS:
        raise ValueError(f"'{action}' is disabled here. {DISABLED_REASON}")
    if action == "kubectl":
        argv = build_kubectl(params.get("command", ""))
    else:
        if action not in ACTIONS:
            raise ValueError(f"unknown action '{action}'")
        argv = ACTIONS[action](params)
    return " ".join(shlex.quote(a) for a in argv), argv


# ── "what this changes" explanations ─────────────────────────────────────────
# tier → derived policy (mirrors the Composition's maps). Kept here so the
# preview can show a true before/after WITHOUT running anything.
TIER_POLICY = {
    "experimental": {"scanCadence": "weekly", "pagingWindow": "none",
                     "escalationPolicy": "none", "sloTarget": "none",
                     "budgetTier": "minimal", "monthlyBudgetUSD": 100},
    "standard":     {"scanCadence": "daily", "pagingWindow": "business-hours",
                     "escalationPolicy": "team-default", "sloTarget": "99.5",
                     "budgetTier": "standard", "monthlyBudgetUSD": 1000},
    "critical":     {"scanCadence": "hourly", "pagingWindow": "24x7",
                     "escalationPolicy": "pd-critical", "sloTarget": "99.95",
                     "budgetTier": "premium", "monthlyBudgetUSD": 10000},
}


def _kubectl_json(args):
    try:
        out = subprocess.check_output(
            ["kubectl", "--context", KUBE_CONTEXT] + args,
            cwd=HERE, stderr=subprocess.DEVNULL, text=True, timeout=8)
        return json.loads(out) if out.strip() else None
    except Exception:
        return None


def explain(action, params):
    """Return a structured 'what this changes' preview (title, summary, diff, bullets)."""
    try:
        if action == "change-tier":
            name = _name(params.get("name"))
            ns = "team-" + _name(params.get("team"), "storefront")
            new = _tier(params.get("tier", "critical"))
            cur_obj = _kubectl_json(["get", "service.lockhead.cloud", name, "-n", ns, "-o", "json"])
            cur = (cur_obj or {}).get("spec", {}).get("tier", "?")
            np, cp = TIER_POLICY.get(new, {}), TIER_POLICY.get(cur, {})
            rows = []
            for key, label in [("scanCadence", "scan cadence"), ("pagingWindow", "paging window"),
                               ("escalationPolicy", "escalation"), ("sloTarget", "SLO target")]:
                rows.append({"label": label, "was": str(cp.get(key, "?")), "now": str(np.get(key, "?"))})
            return {
                "title": f"Change {name}: tier {cur} → {new}",
                "summary": "Edits ONE field (spec.tier) in service-claim.yaml → Git → Argo CD syncs. "
                           "The platform re-derives every downstream policy from the new tier:",
                "field": {"path": "spec.tier", "was": cur, "now": new},
                "rows": rows,
            }
        if action == "add-finops":
            mode = params.get("mode")
            if mode == "remove":
                return {"title": "Revert the FinOps extension",
                        "summary": "Removes the FinOpsAllocation CRD + its Composition block from Git; "
                                   "Argo CD reconciles the platform back to 4 registrations.", "rows": []}
            if mode == "consume":
                return {"title": "Consume the FinOps CRD",
                        "summary": "Read-only: a per-cost-center chargeback rollup off the API. Runs nothing that changes state.", "rows": []}
            svc = _kubectl_json(["get", "xservices.lockhead.cloud", "-o", "json"]) or {}
            n = len(svc.get("items", []))
            return {"title": "Extend the platform: + FinOps (its own Composition)",
                    "summary": "Two moves, committed to Git: (1) a new FinOpsBudget API (XRD) + a "
                               "Composition that DERIVES the allowed budget from the service tier, "
                               "(2) one block so service-onboarding creates a FinOpsBudget per service. "
                               f"~{n} existing service(s) get a derived budget (experimental $100 / "
                               "standard $1000 / critical $10000). Change a tier → the FinOps "
                               "Composition re-derives the budget. No Service API change.",
                    "rows": []}
        if action == "onboard-service":
            name = _name(params.get("name")); team = _name(params.get("team"), "storefront")
            tier = _tier(params.get("tier", "standard")); p = TIER_POLICY.get(tier, {})
            return {"title": f"Onboard '{name}' (scripted golden path)",
                    "summary": f"Scaffolds a repo (app + chart + CI), commits the Service CR, and a per-service "
                               f"Argo app applies it from Git. The platform will then create for team '{team}':",
                    "bullets": ["a deploy (Argo CD Application → chart/)",
                                f"SecurityScan — scan cadence {p.get('scanCadence','?')}",
                                f"OnCallRegistration — paging {p.get('pagingWindow','?')}, SLO {p.get('sloTarget','?')}",
                                "ReportingEntry — central registry record"], "rows": []}
        if action == "build-app":
            name = _name(params.get("name"))
            return {"title": f"Build + deploy the REAL image for '{name}'",
                    "summary": "The end-to-end beat: builds the per-language image FROM the service's own "
                               "scaffolded Dockerfile, pushes it to the in-cluster Gitea registry, and commits "
                               "chart/values.yaml (app.enabled=true + the image ref) back to the repo. Argo CD "
                               "then rolls the Deployment from the offline nginx page over to the real "
                               "Go/TypeScript/Python/PHP container. Reachable at its ingress afterwards.",
                    "bullets": [f"docker build from lockhead/{name}'s Dockerfile",
                                f"push → gitea.cnoe.localtest.me/lockhead/{name}",
                                "GitOps commit flips the deploy to the real image",
                                f"open https://{name}.cnoe.localtest.me:{IDP_PORT}"], "rows": []}
        if action == "onboard-existing":
            return {"title": "Onboard the existing PHP service (GitOps)",
                    "summary": "No scaffolding. Commits a Service CR into lockhead/legacy-orders; a per-service "
                               "Argo app applies it. Same Composition, same fan-out as the golden path.", "rows": []}
        if action == "show-drift":
            name = _name(params.get("name"))
            return {"title": f"Drift → recreate: {name}",
                    "summary": f"DELETES the platform-owned Argo app for '{name}'. The control plane recreates it "
                               "(~2s) — you can't delete your way out of the platform's intent.", "rows": []}
        if action == "reset-service":
            name = _name(params.get("name"))
            return {"title": f"Reset '{name}' — clears ALL traces",
                    "summary": "Deletes the Service CR (cascade-cleans the deploy + registrations), the Backstage "
                               "catalog entry, the Gitea repo, and the GitOps app. Destructive — but reversible by re-onboarding.", "rows": []}
        if action == "reset-all":
            svc = _kubectl_json(["get", "services.lockhead.cloud", "-A", "-o", "json"]) or {}
            items = svc.get("items", [])
            names = [i.get("metadata", {}).get("name", "?") for i in items]
            keep = params.get("keepExtensions")
            fin = _kubectl_json(["get", "crd", "finopsallocations.platform.lockhead.cloud", "-o", "name"])
            obs = _kubectl_json(["get", "crd", "observabilitysetups.platform.lockhead.cloud", "-o", "name"])
            bullets = [f"reset {len(items)} service(s): " + (", ".join(names) if names else "none")]
            if not keep:
                if obs is not None:
                    bullets.append("revert the Observability (Go function) extension")
                if fin is not None:
                    bullets.append("revert the FinOps extension")
            else:
                bullets.append("keep FinOps / Observability extensions in place")
            bullets.append("re-sync the local GitOps checkout (repos/platform-api) to Gitea's baseline")
            return {"title": "Reset the WHOLE demo — back to a clean platform",
                    "summary": "Puts everything back for the next rehearsal, the GitOps way. For every onboarded "
                               "service it clears the Service CR + composed resources, its Gitea repo, its Backstage "
                               "catalog entry and its GitOps app. Extensions are reverted by COMMITTING the baseline "
                               "back to the platform-api repo (Argo CD reconciles), then the local checkout is reset "
                               "to match Gitea. The cluster, Crossplane, Backstage and the platform API itself stay. "
                               "Destructive but fully reversible by re-onboarding.",
                    "bullets": bullets, "rows": []}
        if action == "add-observability":
            mode = params.get("mode")
            if mode == "remove":
                return {"title": "Revert the Observability (Go function) extension",
                        "summary": "Removes the Go Function + ObservabilitySetup API + the Go pipeline step "
                                   "from Git; Argo CD reconciles the platform back.", "rows": []}
            if mode == "consume":
                return {"title": "Consume ObservabilitySetup",
                        "summary": "Read-only: shows each service's alerts/dashboards/routing derived by the Go function.", "rows": []}
            svc = _kubectl_json(["get", "xservices.lockhead.cloud", "-o", "json"]) or {}
            n = len(svc.get("items", []))
            return {"title": "Extend the platform: + Observability (a GO composition function)",
                    "summary": "When the logic outgrows patch-and-transform, drop into Go. Installs a Crossplane "
                               "Function written in Go + adds a Go pipeline STEP to service-onboarding. The function "
                               f"reacts to each service's TIER (alert intensity + routing) and LANGUAGE (runtime "
                               f"dashboards + exporter) — ~{n} service(s) get an ObservabilitySetup. GitOps; the Go "
                               "function image must be prebuilt (packages/4-observability/function/build.sh).",
                    "rows": []}
        if action == "start-target":
            t = params.get("target")
            return {"title": f"Start the '{t}' demo UIs",
                    "summary": "Runs that target's ui.sh with its own kubeconfig file and its own ports "
                               "(port-forwards, dashboard proxy, action backend). This page and its cluster "
                               "keep running; the page opens the other dashboard when it is up. "
                               "The EKS targets need a valid AWS sign-in in the shell that started this backend.",
                    "rows": []}
        if action == "refresh-argo":
            apps = _kubectl_json(["get", "applications", "-n", "argocd", "-o", "json"]) or {}
            n = len(apps.get("items", []))
            return {"title": "Hard-refresh all Argo CD apps",
                    "summary": f"Forces Argo CD to re-dial argocd-repo-server and re-read Git for all ~{n} "
                               "Applications. Safe + idempotent — the fix for a transient "
                               "'argocd-repo-server ... i/o timeout' DNS blip that leaves an app stuck.", "rows": []}
    except Exception as e:
        return {"title": "Preview", "summary": f"(could not compute details: {e})", "rows": []}
    return None


# ── long-running actions: kubectl port-forward ───────────────────────────────
# A port-forward never exits, so it cannot stream like the other actions. The server starts it,
# keeps the process (one per local port, a new one replaces the old) and answers once it is up.
BACKGROUND_ACTIONS = {"port-forward", "port-forward-stop"}
PORT_FORWARDS = {}          # local port -> subprocess.Popen
# Forwards are recorded here so a restarted backend (ui.sh kills it with SIGKILL, which skips atexit)
# can stop the kubectl processes the previous one left behind.
FORWARD_STATE = os.path.join(tempfile.gettempdir(), f"demo-dashboard-forwards-{PORT}.json")  # per backend port: instances must not stop each other's forwards
def _save_state():
    try:
        with open(FORWARD_STATE, "w") as f:
            json.dump({str(k): v.pid for k, v in PORT_FORWARDS.items()}, f)
    except Exception:
        pass
def _kill_stale_forwards():
    try:
        with open(FORWARD_STATE) as f:
            state = json.load(f)
    except Exception:
        return
    for port, pid in state.items():
        try:
            cmd = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True).strip()
        except Exception:
            continue
        # only ever stop a process that is still a kubectl port-forward on that local port
        if "kubectl" in cmd and "port-forward" in cmd and f"{port}:" in cmd:
            try: os.kill(int(pid), signal.SIGTERM)
            except Exception: pass
    try: os.remove(FORWARD_STATE)
    except Exception: pass
_pf_lock = threading.Lock()
def _stop_forward(port):
    proc = PORT_FORWARDS.pop(port, None)
    if proc and proc.poll() is None:
        proc.terminate()
        try: proc.wait(timeout=3)
        except Exception: proc.kill()
    _save_state()
def stop_all_forwards():
    with _pf_lock:
        for port in list(PORT_FORWARDS):
            _stop_forward(port)
atexit.register(stop_all_forwards)
def run_background(action, params, argv):
    """Returns (exit_code, text)."""
    if action == "port-forward-stop":
        with _pf_lock:
            ports = sorted(PORT_FORWARDS)
            for port in ports:
                _stop_forward(port)
        return 0, ("Stopped the port-forward on " + ", ".join(f"localhost:{x}" for x in ports) + "." if ports
                   else "No port-forward is running from this page.")
    port = _port(params.get("port"))
    with _pf_lock:
        _stop_forward(port)
        log = tempfile.TemporaryFile(mode="w+b")
        proc = subprocess.Popen(argv, cwd=HERE, stdout=log, stderr=subprocess.STDOUT,
                                env=dict(os.environ, TERM="dumb", NO_COLOR="1"))
        # kubectl needs several API round trips (slow through the AWS exec plugin) before it
        # listens, so wait for its "Forwarding from" line instead of a fixed delay.
        text = ""
        for _ in range(100):                           # up to ~30 s
            time.sleep(0.3)
            log.seek(0)
            text = strip_ansi(log.read().decode(errors="replace")).strip()
            if proc.poll() is not None:                # it died: address in use, service missing, ...
                text = text or "port-forward exited."
                if "address already in use" in text:
                    text += (f"\n\nLocal port {port} is taken by another program. Change 'Local port' above, "
                             "or set it to 'auto' to pick a free port.")
                return proc.returncode or 1, text
            if "Forwarding from" in text:
                break
        else:
            proc.terminate()
            return 1, (text + "\n\n" if text else "") + "The port-forward did not come up within 30 s."
        PORT_FORWARDS[port] = proc
        _save_state()
    return 0, text + f"\n\nRunning in the background. Open http://localhost:{port}"
# ── HTTP handler ─────────────────────────────────────────────────────────────
# Only pages served from localhost (the demo dashboards on any port) may call this
# backend from a browser. Without this, any website open in the same browser could
# POST to it (cross-site request) or reach it through DNS rebinding.
ALLOWED_ORIGIN_RE = re.compile(r"^http://(localhost|127\.0\.0\.1)(:\d{1,5})?$")
ALLOWED_HOSTS = {f"localhost:{PORT}", f"127.0.0.1:{PORT}"}


class Handler(BaseHTTPRequestHandler):
    def _origin_ok(self):
        origin = self.headers.get("Origin")
        return origin is None or bool(ALLOWED_ORIGIN_RE.match(origin))

    def _host_ok(self):
        return (self.headers.get("Host") or "") in ALLOWED_HOSTS

    def _cors(self):
        origin = self.headers.get("Origin")
        if origin and ALLOWED_ORIGIN_RE.match(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")

    def _forbidden(self):
        self._json(403, {"error": "forbidden: only pages on localhost may call this backend"})

    def do_OPTIONS(self):
        if not (self._host_ok() and self._origin_ok()):
            return self._forbidden()
        self.send_response(204); self._cors(); self.end_headers()

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if not (self._host_ok() and self._origin_ok()):
            return self._forbidden()
        if self.path == "/health":
            return self._json(200, {"ok": True, "actions": sorted(list(ACTIONS) + ["kubectl"]),
                                    "kubectlWrite": ALLOW_KUBECTL_WRITE,
                                    "disabled": sorted(DISABLED_ACTIONS),
                                    "disabledReason": DISABLED_REASON if DISABLED_ACTIONS else "",
                                    "target": DEMO_TARGET, "context": KUBE_CONTEXT})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not (self._host_ok() and self._origin_ok()):
            return self._forbidden()
        try:
            n = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(n) or "{}")
        except Exception as e:
            return self._json(400, {"error": f"bad request: {e}"})

        action = payload.get("action", "")
        params = payload.get("params", {}) or {}

        # /preview — return the command string + a "what this changes" explanation.
        # Runs nothing that mutates state (explain may do read-only kubectl gets).
        if self.path == "/preview":
            try:
                cmd, _ = preview_for(action, params)
                resp = {"command": cmd}
                if action != "kubectl":
                    exp = explain(action, params)
                    if exp:
                        resp["explain"] = exp
                return self._json(200, resp)
            except Exception as e:
                return self._json(400, {"error": str(e)})

        # /run — validate, then stream stdout+stderr as the command runs.
        if self.path == "/run":
            try:
                cmd, argv = preview_for(action, params)
            except Exception as e:
                return self._json(400, {"error": str(e)})
            self.send_response(200); self._cors()
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(("$ " + cmd + "\n\n").encode())
            self.wfile.flush()
            if action in BACKGROUND_ACTIONS:
                try:
                    code, text = run_background(action, params, argv)
                except Exception as e:
                    code, text = 1, f"error: {e}"
                self.wfile.write((text + f"\n\n[exit {code}]\n").encode())
                return
            try:
                # TERM=dumb discourages most tools from emitting colors; we also
                # strip any ANSI codes that slip through so the browser shows clean text.
                env = dict(os.environ, TERM="dumb", NO_COLOR="1")
                proc = subprocess.Popen(argv, cwd=HERE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, bufsize=1, text=True, env=env)
                for line in proc.stdout:
                    try:
                        self.wfile.write(strip_ansi(line).encode()); self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        proc.terminate(); return
                proc.wait()
                self.wfile.write((f"\n[exit {proc.returncode}]\n").encode())
            except Exception as e:
                try: self.wfile.write(f"\n[error running command: {e}]\n".encode())
                except Exception: pass
            return

        self._json(404, {"error": "not found"})

    def log_message(self, *a):  # quiet
        pass


def main():
    _kill_stale_forwards()
    # 127.0.0.1 ONLY — never bind to 0.0.0.0.
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"dashboard-server on http://127.0.0.1:{PORT}  "
          f"(kubectl writes: {'ON' if ALLOW_KUBECTL_WRITE else 'off'})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
