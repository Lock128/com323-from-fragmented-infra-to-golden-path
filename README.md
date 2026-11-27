# From Fragmented Infra to Golden Path: An IDP on EKS

Companion repository for **COM323**, a Code Talk at AWS re:Invent 2026
(Las Vegas, Wednesday 13:30, Caesars Forum, Forum 120).
Speaker: Johannes Koch.

A developer onboards a service through a portal (Backstage). The platform then
creates the Git repository from a template (app, Dockerfile, Helm chart, CI
pipeline), deploys it with Argo CD, and registers it with downstream systems
(security scanning, SRE on-call, central reporting). Crossplane and Argo CD are
the engine. The developer writes only `name`, `team` and `tier`.

```
Developer ──▶ Backstage "Onboard a new service"  (or: kubectl apply a Service CR)
                 ├─ publish:gitea     ──▶ new Git repo scaffolded from a skeleton
                 ├─ catalog:register  ──▶ entry in the Backstage catalog
                 └─ apply Service CR  ──▶ Crossplane "service-onboarding" Composition
                                           ├─ Argo CD Application (deploys the app)
                                           ├─ security scan registration (cadence by tier)
                                           ├─ SRE on-call registration (paging by tier)
                                           └─ central reporting entry
```

## What is in here

| Folder | Contents |
| --- | --- |
| [`local-demo/`](./local-demo) | The full demo on a local kind cluster, based on [CNOE idpbuilder](https://github.com/cnoe-io/idpbuilder) (Argo CD, Gitea, Backstage, Crossplane). Includes the browser-driven demo UI, the optional FinOps extension and the Go composition function for observability. Start with its [README](./local-demo/README.md). |
| [`eks-infrastructure/`](./eks-infrastructure) | AWS CDK (TypeScript) app that deploys the same golden path on Amazon EKS Auto Mode. It reuses the manifests in `local-demo/packages/`, so the developer-facing API is identical. See its [README](./eks-infrastructure/README.md). |
| [`eks-infrastructure-managed/`](./eks-infrastructure-managed) | The alternative shown on the "fully managed" slide: the same `Service` API on EKS Capabilities (managed Argo CD, kro and ACK) with CodeCommit instead of Gitea. See its [README](./eks-infrastructure-managed/README.md). Not yet verified on a live deployment; the README lists what is untested. |

`eks-infrastructure/` and `local-demo/` refer to each other by relative path.
Keep them side by side at the repository root. `eks-infrastructure-managed/`
deploys independently of both; only its optional read-only dashboard uses the
pages in `local-demo/`.

## Quick start (local)

Prerequisites: Docker, `idpbuilder`, `helm`, `kubectl`.

```bash
cd local-demo
./start.sh          # kind + Argo CD + Gitea + Backstage + Crossplane (5-20 min on first run)
./setup_gitops.sh   # installs the Service API and wires the portal template
./ui.sh             # opens the demo dashboard and the tool UIs
```

## Quick start (EKS)

Prerequisites: Node.js 24, AWS credentials, and a CDK-bootstrapped account and region.

```bash
cd eks-infrastructure
npm ci && npm run build
npx cdk deploy --all
```

The [EKS README](./eks-infrastructure/README.md) has the bootstrap step, the
context options and the kubeconfig setup.

`eks-infrastructure-managed/` deploys with `./scripts/deploy.sh` and needs an IAM
Identity Center instance configured in its `cdk.json`.

Both create billable resources (EKS cluster, NAT gateways, load balancers).
Destroy them when you are done (`npx cdk destroy --all`).

## Switching between local, EKS and managed EKS

Each of the three targets has its own kubeconfig file and its own ports, so they
can run at the same time. No script changes the current context of
`~/.kube/config`.

| Target | kubeconfig | Dashboard | Started by |
| --- | --- | --- | --- |
| `local` | `~/.kube/kind-com323.yaml` | http://localhost:8111/ui/dashboard.html | `local-demo/ui.sh` |
| `eks` | `~/.kube/lockheadcloud-idp` | http://localhost:8011/ui/dashboard.html | `eks-infrastructure/scripts/ui.sh` |
| `managed` | `~/.kube/lockheadcloud-managed` | http://localhost:8021/ui/dashboard.html (read-only) | `eks-infrastructure-managed/scripts/ui.sh` |

[`local-demo/target.sh`](./local-demo/target.sh) manages all three:

```bash
cd local-demo
./target.sh status               # kubeconfig, cluster and UI state of each target
./target.sh start eks            # start a target's UIs (runs its ui.sh)
./target.sh stop all             # stop the UIs these scripts started
eval "$(./target.sh env eks)"    # point kubectl in THIS shell at a target
./target.sh kubeconfig all       # rewrite every target's kubeconfig file
./target.sh reset                # stop all, rewrite the files, and move demo EKS contexts
                                 # out of ~/.kube/config (backed up first)
```

In the dashboard, demo flow and live view pages, the **Cluster** picker at the top
shows the target the page runs against. Picking another target opens its
dashboard, and starts its UIs first if they are not running. The EKS targets need
a valid AWS sign-in in the shell that started the dashboard.

## Scope and caveats

- This is demo-grade code. Gitea and Backstage run with literal passwords, Argo
  CD serves plain HTTP and the Crossplane provider has broad RBAC. The EKS
  README lists what to change for a real platform.
- The security, SRE and reporting systems are stood in with ConfigMaps. The
  pattern is the same in production; only the leaf resources change.
- `local-demo/packages/4-observability/function/build.sh` builds the Go
  function and its package locally. Binaries are not committed.
- The `default` AWS profile name in the deploy scripts is a placeholder. Set
  `IDP_AWS_PROFILE` to your own profile.
- Some scripts have an optional path for corporate TLS-inspection proxies
  (they mention Zscaler). You can ignore it on a normal network.
- The dashboard's action backend runs shell commands on your machine. It only
  listens on `127.0.0.1`. See [SECURITY.md](./SECURITY.md).

## Credits

The local demo is built on [CNOE](https://cnoe.io) (Cloud Native Operational
Excellence):

- [CNOE idpbuilder](https://github.com/cnoe-io/idpbuilder) creates the kind
  cluster with Argo CD and Gitea.
- The Backstage install
  ([`local-demo/packages/5-backstage/install.yaml`](./local-demo/packages/5-backstage/install.yaml))
  is adapted from the reference implementation in
  [cnoe-io/stacks](https://github.com/cnoe-io/stacks), and uses CNOE's
  Backstage image with its `cnoe:kubernetes:apply` scaffolder action. The EKS
  variants port the same manifests.

Both CNOE projects are licensed under the Apache License 2.0. See [NOTICE](./NOTICE).

## Branding

The Apache 2.0 license covers the code and written material in this
repository, not AWS trademarks.

## License

[Apache License 2.0](./LICENSE), the same license as CNOE idpbuilder. See also [NOTICE](./NOTICE).
