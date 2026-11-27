# Local Demo — Service Onboarding Golden Path

A self-contained local IDP that shows the **service-onboarding golden path** from
the re:Invent 2026 talk, built on the [CNOE idpbuilder](https://github.com/cnoe-io/idpbuilder)
baseline (kind + Argo CD + Gitea + Backstage). Runs entirely offline.

## What this demo shows

A developer onboards a new service through the internal developer portal. One
form (or one `Service` CR) fans out into the whole golden path:

```
Developer  ──▶  Backstage "Onboard a new service"  (or: kubectl apply a Service CR)
                     │
                     ├─ publish:gitea      ──▶ NEW Git repo, scaffolded from a skeleton
                     │                          (app + Dockerfile + Helm chart + CI/CD pipeline)
                     ├─ catalog:register   ──▶ registered in the Backstage software catalog
                     └─ apply Service CR   ──▶ Crossplane service-onboarding Composition:
                                                 ├─ Argo CD Application  ──▶ deploys the app
                                                 ├─ security scan registration   (cadence by tier)
                                                 ├─ SRE on-call registration      (paging by tier)
                                                 └─ central reporting entry
```

The developer writes `name` + `team` + `tier`. The platform decides **where** it
deploys, **who** gets paged, **how often** it's scanned, and registers it with
every downstream system — no tickets, no manual wiring.

Everything is real: a real Git repo, a real Argo CD Application, real Kubernetes
objects. The security/SRE/reporting systems are stood in with ConfigMaps so the
whole thing runs offline on kind — the pattern is identical in production; only
the "leaf" resources change.

## Prerequisites

| Tool | Install |
| --- | --- |
| Docker | [docker.com/get-started](https://www.docker.com/get-started/) |
| idpbuilder | `brew install cnoe-io/tap/idpbuilder` or [GitHub releases](https://github.com/cnoe-io/idpbuilder/releases) |
| helm | `brew install helm` |
| kubectl | `brew install kubectl` |

## Quick start

```bash
cd local-demo
./start.sh          # brings up kind + Argo CD + Gitea + Backstage + Crossplane
./setup_gitops.sh   # installs the Service API (XRD + Composition) + wires the portal template
./ui.sh             # opens the live dashboard + Argo CD / Gitea / Backstage / Crossview
```

First `start.sh` takes ~5–20 min depending on the network (see Troubleshooting).

## Running the golden-path demo

### Portal path (what you show on stage)

1. Open Backstage (`http://localhost:7207`, sign in `demo@example.com` / `password`).
2. **Create → "Onboard a new service"**.
3. Fill the form: service name (e.g. `checkout`), team (e.g. `storefront`),
   language, tier. Click **Create**.
4. Watch the platform: a Git repo appears in Gitea, an Argo CD Application spins
   up and deploys the app, and the service is registered downstream.

### Scripted path (fast / offline fallback)

```bash
# 1. Onboard — creates the repo + scaffold, then a per-service Argo CD app
#    (svc-checkout) applies the Service CR from Git (GitOps, like the portal).
./demo/onboard-service.sh checkout storefront          # name team [language] [tier]

# 2. The repository the platform created (app, Dockerfile, chart, CI pipeline)
./demo/show-repo.sh checkout

# 3. The Argo CD Application + the running workload it deployed
./demo/show-deploy.sh checkout storefront

# 4. The downstream registrations (security scan, SRE on-call, reporting)
./demo/show-registrations.sh checkout

# 5. THE MONEY MOMENT — change one field; policy re-derives everywhere
./demo/change-tier.sh checkout storefront critical

# 6. Drift & self-healing — hand-edit the platform-owned Argo app; it heals back
./demo/show-drift.sh checkout

# Single pane of glass — every service + its fan-out
./demo/list-services.sh

# If an Argo app gets stuck ("argocd-repo-server … i/o timeout" — a transient
# in-cluster DNS blip), hard-refresh them all:
./demo/refresh-argo.sh

# Reset so you can run it again (clears K8s + Backstage + Gitea + GitOps)
./demo/reset-service.sh checkout storefront
```

### Onboard an EXISTING service (the "second door")

A pre-built **PHP** service (`lockhead/legacy-orders`) is seeded into Gitea at
cluster start. Onboard it without any scaffolding — just declare its `Service` CR:

```bash
./demo/onboard-existing.sh            # GitOps: commit the CR, Argo CD applies it
./demo/onboard-existing.sh --direct   # or kubectl apply the CR directly
```

Or use the Backstage portal: **Create → "Onboard an existing service"**, pointing
at an existing repo URL. Same Composition, same fan-out — zero new code.

### The one thing the developer writes

```yaml
apiVersion: lockhead.cloud/v1alpha1
kind: Service
metadata:
  name: checkout
  namespace: team-storefront
spec:
  name: checkout
  team: storefront
  language: go
  tier: standard
  repoURL: http://my-gitea-http.gitea.svc.cluster.local:3000/lockhead/checkout.git
  repoPath: chart
```

Everything else — the Argo CD Application, the security/SRE/reporting
registrations — is derived by the platform.

## Direct apply vs. GitOps

The demo uses both apply styles on purpose. Every onboarding path is GitOps by
default; the direct ones are explicit opt-ins, fallbacks or demo actions.

| Action | How the CR/change reaches the cluster | Style |
| --- | --- | --- |
| Backstage "Onboard a new service" | `publish:gitea` commits `service-claim.yaml` to the service repo; the template creates a per-service Argo CD app (`svc-<name>`) that applies it | **GitOps** |
| `./demo/onboard-service.sh` | pushes `service-claim.yaml` to the service repo; a per-service Argo CD app (`svc-<name>`) applies it | **GitOps** |
| `./demo/onboard-existing.sh` (default) | commits `service-claim.yaml` to the service's own repo; `svc-<name>` applies it | **GitOps** |
| `./demo/onboard-existing.sh --direct` | `kubectl apply` of the CR | **Direct** (opt-in / offline fallback) |
| Backstage "Onboard an existing service" | scaffolder `cnoe:kubernetes:apply` of the Service CR | **Direct** |
| `./demo/change-tier.sh` | `kubectl patch` of the Service CR | **Direct** |
| `./demo/show-drift.sh` | `kubectl delete` of the Argo CD app (the platform recreates it) | **Direct** |
| `./demo/reset-service.sh` | `kubectl delete` sweep, and removes the CR from Git | **Direct + Git** |
| `./demo/add-finops.sh` | commits the FinOps XRD, Composition and onboarding block to `platform-api`; Argo CD syncs | **GitOps** |
| `./demo/add-observability.sh` | commits the Go Function, the ObservabilitySetup CRD and a pipeline step to `platform-api`; Argo CD syncs | **GitOps** (image prebuilt) |
| Platform install (`setup_gitops.sh`) | `platform-xrds` / `platform-compositions` Argo CD apps from Gitea | **GitOps** |
| Platform install (`setup_direct.sh`) | `kubectl apply` of the XRDs and Compositions | **Direct** |

Full rebuilds: `./recreate.sh` deletes the kind cluster (in-cluster Gitea, all
repos and every CR) and the local `repos/` clone, then rebuilds with
`setup_gitops.sh`. Afterwards the platform is at its base (no FinOps or
Observability extension). `./recreate-direct.sh` does the same with
`setup_direct.sh`. The demo scripts never modify your source tree; they write to
throwaway clones and the in-cluster Gitea only.

## Cleanup

```bash
./stop.sh
```

## Architecture notes

| Path | What it does |
| --- | --- |
| `packages/1-crossplane/` | Crossplane + provider-kubernetes + function-patch-and-transform |
| `packages/2-platform-api/xrds/service-xrd.yaml` | The `Service` API developers declare |
| `packages/2-platform-api/compositions/service-onboarding.yaml` | Fans a `Service` out into Argo CD app + 3 downstream registrations |
| `packages/4-gitops/` | Argo CD Applications that install the platform API from Gitea |
| `packages/5-backstage/service-template/` | The "Onboard a new service" portal template + app skeleton |
| `packages/5-backstage/existing-service-template/` | The "Onboard an existing service" portal template (no scaffold) |
| `example-repos/legacy-orders/` | Pre-built **PHP** service, seeded into Gitea at start — onboard it as "existing" |
| `seed-example-repos.sh` | Pushes `example-repos/*` into Gitea (run by `start.sh`) |
| `demo/` | Scripted onboarding, the money moment, drift, and inspection scripts |

`provider-kubernetes` uses `InjectedIdentity` (in-cluster SA, bound cluster-admin
for the demo). It creates real Kubernetes objects — the Argo CD Application is a
real deployment; the security/SRE/reporting ConfigMaps stand in for real
downstream systems and swap out without touching the developer-facing `Service` API.

## Running two demos side by side

Everything that must be unique per instance lives in [`instance.env`](./instance.env),
which every script sources. This copy is the **second** instance; the original uses
the values in the right-hand column.

| What | This instance | Original |
| --- | --- | --- |
| kind cluster / context (`DEMO_NAME`) | `com323` / `kind-com323` | `lockheadcloud` / `kind-lockheadcloud` |
| kubeconfig | `~/.kube/kind-com323.yaml` (own file) | `~/.kube/config` |
| idpbuilder web UI / ingress (`IDP_PORT`) | `https://*.cnoe.localtest.me:8643` | `:8543` |
| gitea NodePort host port (`GITEA_HOST_PORT`) | `32323` | `32223` |
| Argo CD (`ARGOCD_PORT`) | `http://localhost:18280` | `18180` |
| Gitea (`GITEA_PORT`) | `http://localhost:3200` | `3100` |
| Backstage (`BACKSTAGE_PORT`) | `http://localhost:7207` (sign in `demo@example.com` / `password`) | `7107` |
| Dex OIDC (`DEX_PORT`) | `http://localhost:5756` | `5656` |
| Crossview (`CROSSVIEW_PORT`) | `http://localhost:9290` | `9190` |
| Dashboard / live view (`DASH_PORT`) | `http://localhost:8111/ui/dashboard.html` | `8011` |
| Dashboard action backend (`CTL_PORT`) | `http://localhost:8112` | `8012` |
| Local port-forward to an onboarded app (`APP_PORT`) | `8180` | `8080` |

Pages: `http://localhost:8111/ui/dashboard.html` (control panel), `/ui/show.html` (live
view for the audience), `/ui/demo-flow.html` (every step in order, run from the page).
On the demo flow page, the bar above the steps sets the service name, team, language and tiers for all steps. Tick **Use a different service/team per step** to get fields on each step; an empty field uses the value from the bar. **Show current kubeconfig** shows which cluster the steps run against (`demo/show-context.sh`). The **kubectl** box runs read-only commands (get, describe, logs, top, events, `rollout status`) against the same cluster.

**How the isolation works**

- Each instance has its own kubeconfig file. idpbuilder itself only knows `~/.kube/config`,
  so `start.sh` lets it write there and then copies the `kind-com323` context into
  `~/.kube/kind-com323.yaml`. All scripts export `KUBECONFIG` for that file (from
  `instance.env`), so `kubectl config use-context` in one instance never switches the
  other. For your own `kubectl` in a terminal: `eval "$(./target.sh env local)"`
  (or `export KUBECONFIG=~/.kube/kind-com323.yaml`).
- The HTML/JS pages, `packages/5-backstage/install.yaml` and the Backstage templates keep
  the **original** port numbers in the repo, because `eks-infrastructure/` shares them.
  The scripts rewrite them to this instance's ports on the way out (`ui.sh` serves a
  rewritten copy, `start.sh` applies a rewritten `install.yaml`, `setup_*.sh` /
  `reload-template.sh` push rewritten templates to Gitea).
- `stop.sh` / `ui.sh` stop only the listeners on this instance's ports, not every
  `kubectl port-forward` on the machine. `./target.sh stop local` stops only the
  processes this instance's `ui.sh` started (it records their PIDs).
- Cookies are per host, not per port. Argo CD, Gitea and Dex all set cookies on
  `localhost`, so logging in to both instances in the **same browser profile** logs the
  other one out. Use a second browser profile or a private window for the second instance.

Use a different block for a third instance:

```bash
DEMO_NAME=demo3 IDP_PORT=8743 GITEA_HOST_PORT=32423 ARGOCD_PORT=18380 GITEA_PORT=3300 \
BACKSTAGE_PORT=7307 DEX_PORT=5856 CROSSVIEW_PORT=9390 DASH_PORT=8211 CTL_PORT=8212 \
APP_PORT=8280 ./start.sh
```

(export the same variables for `setup_gitops.sh`, `ui.sh` and the `demo/` scripts, or put them in `instance.env`.)

> **Why `GITEA_HOST_PORT`?** idpbuilder's built-in kind template hardcodes a
> `32222:32222` host-port mapping that neither `--port` nor `--extra-ports` can
> remove, so a second idpbuilder cluster collides with
> `Bind for 0.0.0.0:32222 failed: port is already allocated`. `start.sh` works
> around this by passing a rendered copy of `kind-config.yaml` (`--kind-config`) that moves
> that host port to `GITEA_HOST_PORT`. Gitea is still reached through a
> `kubectl port-forward`, so the NodePort host port is otherwise unused.

The **dashboard's live view** polls the cluster every 2s and shows the golden path
as it happens: each **Service** declaration on the left, and on the right the
resources the platform produced from it — the **Git repository**, the **Argo CD
application + running workload**, and the three downstream registrations
(**security scan**, **SRE on-call**, **reporting**). New/changed resources glow;
removed ones fade. It must be opened via `./ui.sh` (which runs `kubectl proxy` so
the page can read the cluster same-origin); opened as a `file://` it still shows
the static content but the live view stays blank.

## Switching between local, EKS and managed EKS (`target.sh`)

The same pages and demo scripts run against three targets. Each has its own
kubeconfig file and its own ports, so they can run side by side, and none of them
changes the current context of `~/.kube/config`:

| Target | kubeconfig | Dashboard | Action backend | Started by |
| --- | --- | --- | --- | --- |
| `local` | `~/.kube/kind-com323.yaml` | `:8111` | `:8112` | `./ui.sh` |
| `eks` | `~/.kube/lockheadcloud-idp` | `:8011` | `:8012` | `../eks-infrastructure/scripts/ui.sh` |
| `managed` | `~/.kube/lockheadcloud-managed` | `:8021` | `:8022` | `../eks-infrastructure-managed/scripts/ui.sh` |

```bash
./target.sh status                 # per target: kubeconfig, context, reachable?, UIs running?
                                   # plus the current context of ~/.kube/config and this shell
./target.sh start <target>         # run that target's ui.sh (--no-open: no browser tabs)
./target.sh stop <target|all>      # stop the processes that ui.sh recorded (--force: also any
                                   # kubectl / dashboard-server listener on the target's ports)
eval "$(./target.sh env eks)"      # point kubectl in your shell at a target
./target.sh kubeconfig <target|all>  # rewrite the kubeconfig file(s); EKS ones need AWS sign-in
./target.sh reset                  # stop everything, rewrite all kubeconfig files, and remove the
                                   # demo EKS contexts from ~/.kube/config (asks; --yes skips)
```

`reset` copies `~/.kube/config` to `~/.kube/config.bak-<timestamp>` before it changes
anything, and only removes an EKS context once its own kubeconfig file has it. If
the removed context was the current one, `current-context` is unset. The
`kind-com323` context stays in `~/.kube/config`, because idpbuilder only writes
there.

**In the browser:** the dashboard, demo flow and live view have a **Cluster**
picker at the top. It shows which target the page runs against (with the kube
context) and the state of the other targets. Picking another target opens its
dashboard. If it is not running, the page's action backend starts it first
(`./target.sh start <target> --no-open`, shown in a panel) and the page switches
once it is up. This page and its cluster keep running. Starting `eks` or
`managed` needs a valid AWS sign-in in the shell that started the backend.

On `managed` the dashboard is read-only: the live view, the kubectl box and the
inspect steps (`show-registrations`, `show-deploy`, `list-services`,
`show-context`) work, because kro produces the same `Service` API, Argo CD
Applications and registration CRDs. The steps that need Gitea or Crossplane
(onboard, change tier, extensions, drift, reset) are disabled there. The Argo CD,
Gitea and Crossview links on that dashboard do not apply; managed Argo CD has its
own URL (printed by its `ui.sh`).

## Troubleshooting

### `ImagePullBackOff` on ingress-nginx / gitea (fresh build behind a proxy)

If you're behind a corporate SSL-inspection proxy (e.g. Zscaler), a cold build can
stall with pods stuck in `ImagePullBackOff`. Two root causes:

1. **Blocked DNS** — kind nodes default to Docker Desktop's resolver
   (`192.168.65.254`). Symptom in pod events: `server misbehaving` / `no such host`.
2. **Untrusted proxy CA** — pulls fail with
   `x509: certificate signed by unknown authority`.

`start.sh` **self-heals** both: it runs `idpbuilder` in the background, waits for
the kind node container to appear, then patches node DNS (`8.8.8.8`) and injects
the Zscaler CA (from the macOS System keychain) into the node trust store — all
*before* idpbuilder blocks on ingress-nginx readiness. On a clean network this is
a no-op.

If a build still gets stuck, apply the fixes manually while it runs:

```bash
# 1. Node DNS
for n in $(docker ps --filter label=io.x-k8s.kind.cluster=com323 --format '{{.Names}}'); do
  docker exec "$n" bash -c 'printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf'
done

# 2. Zscaler CA into the node trust store
security find-certificate -a -p -c "Zscaler" /Library/Keychains/System.keychain > /tmp/zscaler-ca.pem
for n in $(docker ps --filter label=io.x-k8s.kind.cluster=com323 --format '{{.Names}}'); do
  docker cp /tmp/zscaler-ca.pem "$n:/usr/local/share/ca-certificates/zscaler.crt"
  docker exec "$n" update-ca-certificates --fresh
  docker exec "$n" systemctl restart containerd
done

# 3. Bounce the stuck pods so they re-pull
kubectl --context kind-com323 -n ingress-nginx delete pod --all --force --grace-period=0
kubectl --context kind-com323 -n gitea delete pod --all --force --grace-period=0
```

### I changed the Backstage template — the portal still uses the old one

Editing `packages/5-backstage/service-template/` is **not enough**. Backstage reads
the template from the Gitea `platform-api` repo, and the catalog caches the parsed
entity. A `kubectl rollout restart` does **not** fix it — the catalog processor
re-registers the cached entity before it re-reads the file, so the portal keeps
serving the stale template (you'll see onboarding fail at **Register in the software
catalog** with a wrong `catalog-info.yaml` URL).

Run the one command that does the whole dance — push the template to Gitea, then
force a catalog **refresh** of the template's Location, then verify the live
`register` step picked up your edit:

```bash
./reload-template.sh
```

It prints the live `repoContentsUrl` / `catalogInfoPath` at the end so you can
confirm the change is active. Then onboard a **new** service name to test.

> Why the register step is fragile: `catalog:register` resolves
> `repoContentsUrl` + `catalogInfoPath` through Backstage's `defaultScmResolveUrl`.
> `repoContentsUrl` **must** end with a trailing slash (`…/src/branch/main/`) and
> `catalogInfoPath` **must** be relative (`catalog-info.yaml`, no leading `/`).
> Otherwise the branch gets dropped and Gitea 404s. The template is already set up
> this way — don't "simplify" those two values.

### Reset a service (clear ALL traces)

```bash
./demo/reset-service.sh <service-name> <team>     # e.g. checkout storefront
```

This removes every trace of an onboarding so the name can be reused cleanly:

1. **Kubernetes** — deletes the `Service` CR (Crossplane cascade-deletes the Argo CD
   app + the security/SRE/reporting registrations), plus a label-based sweep.
2. **Backstage** — deregisters the catalog **Location + Component** the onboarding
   created. (The old reset skipped this, which left orphaned entries and caused
   `409 Location already exists` on the next onboarding with the same name.)
3. **Gitea** — deletes the service's repository under the `lockhead` org.

Needs Backstage + Gitea reachable (via `./ui.sh`); the script starts temporary
port-forwards if they aren't already up.

### For the live talk

Cold builds take ~20+ min behind a proxy and depend on the network. **Build the
cluster ahead of time and leave it running** — a warm cluster is fast and offline.
Only run `./stop.sh` when you're completely done. Keep the recorded video fallback
handy.
