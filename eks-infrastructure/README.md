# IDP-on-EKS Infrastructure (CDK)

The AWS deployment of the re:Invent 2026 **service-onboarding golden path**.

The [`local-demo/`](../local-demo) runs the whole IDP on a local **kind** cluster
via CNOE idpbuilder. This CDK app provisions the **cloud** counterpart: a managed
**EKS Auto Mode** cluster, its VPC, IAM roles (OIDC/IRSA), and the same platform
API (Crossplane + `Service` XRD + `service-onboarding` Composition) installed on
top — so the identical golden path runs on AWS instead of on your laptop.

Built on the [aws-eks-v2 L2 constructs with EKS Auto Mode](https://aws.amazon.com/blogs/devops/announcing-the-new-aws-cdk-eks-v2-l2-constructs/):
AWS manages compute (Karpenter), storage (EBS CSI), and the load balancer
controller as built-in components, so there's **no node group, no add-ons, and
no EBS CSI IRSA role** to define — EKS provisions capacity on demand.

## What gets deployed

Two stacks:

| Stack | What it creates |
| --- | --- |
| `IdpVpcStack` | A VPC with public + private (egress) subnets across up to 3 AZs, tagged for Kubernetes ELB discovery. |
| `IdpEksStack` | An **EKS Auto Mode** cluster (public + private endpoint) in the VPC, a kubectl provider (for `addManifest`/`addHelmChart`), an OIDC provider for IRSA, a cluster-admin access entry, and the **platform baseline + portal** (see below). |

The platform baseline (`lib/platform-bootstrap.ts`) mirrors `start.sh` +
`setup_gitops.sh` from the local demo, but on EKS:

1. **Crossplane** (Helm, v2.4.0)
2. **provider-kubernetes** + **function-patch-and-transform** (Crossplane packages)
3. RBAC + a `ProviderConfig` named `in-cluster` (same as local)
4. **Argo CD** (Helm, self-hosted) — the GitOps engine the Composition targets
5. **Crossview** (Helm) — the Crossplane resource browser
6. A default **gp3 StorageClass** using the Auto Mode EBS provisioner
   (`ebs.csi.eks.amazonaws.com`) for the portal's PVCs
7. The downstream-system namespaces (`security-system`, `sre-system`, `platform-reporting`)
8. The **`Service` XRD + `service-onboarding` Composition** — read verbatim from
   `../local-demo/packages/2-platform-api/`, so the developer-facing API is
   byte-for-byte the same as the local demo.

The developer-facing **portal** (`lib/idp-portal.ts`) stands in for what
idpbuilder provides locally, so the full "Onboard a new service" golden path
runs end to end on AWS:

9. **Gitea** (Helm, PVC-backed) at the same in-cluster address the local demo
   uses — `my-gitea-http.gitea.svc.cluster.local:3000` — admin `giteaAdmin`,
   credential in secret `gitea/gitea-credential`.
10. A **seed Job** that creates the `platform-api` Gitea repo and pushes the
    XRD + Composition + Backstage catalog + `service-template/` into it (the
    host-side git push `setup_gitops.sh` does locally, moved into the cluster).
11. The two platform **ArgoCD Applications** (`platform-xrds`,
    `platform-compositions`) that sync that repo, plus the Argo CD repo secret.
12. **Backstage + Dex + Postgres** (adapted from
    `../local-demo/packages/5-backstage/install.yaml`), including the CNOE
    backstage image with the `cnoe:kubernetes:apply` scaffolder action.

> **Demo-grade, not production.** Gitea (SQLite) and Backstage (single Postgres
> pod) run in-cluster on PVC storage (matching the local demo).
> Argo CD serves insecure HTTP, the Gitea/Backstage passwords are literals in
> the manifests, and provider-kubernetes runs broad RBAC. For a real platform
> you'd move secrets to Secrets Manager, back Gitea/Postgres with RDS, front
> the UIs with an ALB + ACM + OIDC, and scope RBAC down.

## Prerequisites

- Node.js 24
- AWS credentials for the target account (CLI profile or env vars)
- An account/region that has been **CDK-bootstrapped** (the EKS construct needs
  it for its asset buckets and kubectl Lambda):
  ```bash
  npx cdk bootstrap aws://<account-id>/<region>
  ```

## Deploy from your local PC

```bash
cd eks-infrastructure
npm ci
npm run build

# Optional but recommended: grant your own IAM principal kubectl cluster-admin,
# so you can drive the cluster after it comes up.
export CDK_DEFAULT_ACCOUNT=<account-id>
export CDK_DEFAULT_REGION=us-west-2

npx cdk deploy --all \
  --context adminPrincipalArn=arn:aws:iam::<account-id>:role/<your-role>
```

The scripts in `scripts/` use their own kubeconfig file, `~/.kube/lockheadcloud-idp`
([`scripts/kubeconfig.sh`](./scripts/kubeconfig.sh)), and do not change the current
context of `~/.kube/config`. `./scripts/deploy.sh` writes it after a deploy, and
`ui.sh`, `apply.sh` and `reset.sh` create it if it is missing. If you deployed
without the script, write it with the `UpdateKubeconfigCommand` output of the
`IdpEksStack` plus `--kubeconfig`:

```bash
aws eks update-kubeconfig --name lockheadcloud-idp --region us-west-2 \
  --role-arn <ClusterMastersRole ARN from the output> --kubeconfig ~/.kube/lockheadcloud-idp

eval "$(../local-demo/target.sh env eks)"    # = export KUBECONFIG=~/.kube/lockheadcloud-idp
kubectl get nodes
kubectl get providers.pkg.crossplane.io      # provider-kubernetes Healthy
kubectl get xrd                              # xservices.lockhead.cloud Established
kubectl get composition                      # service-onboarding
```

### Open the UIs + the live dashboard (`scripts/ui.sh`)

The cloud equivalent of the local `ui.sh`. It uses the cluster's own kubeconfig
file, starts the `kubectl port-forward`s (so the browser-facing `localhost` URLs
baked into Backstage/Dex work), and serves the live **dashboard** via `kubectl proxy`:

```bash
./scripts/ui.sh                       # CLUSTER_NAME / AWS_REGION env override the defaults
../local-demo/target.sh start eks     # the same, from the target switcher
../local-demo/target.sh stop eks      # stop the forwards, proxy and backend it started
```

To switch between this cluster, the local kind demo and the managed variant, see
[Switching between local, EKS and managed EKS](../local-demo/README.md#switching-between-local-eks-and-managed-eks-targetsh).

| UI | URL | Credentials |
| --- | --- | --- |
| **Dashboard (live view + run the demo)** | http://localhost:8011/ui/dashboard.html | — |
| **Live view only** (audience screen) | http://localhost:8011/ui/show.html | — |
| **Demo flow** (every step, run from the page) | http://localhost:8011/ui/demo-flow.html | — |
| Backstage | http://localhost:7107 | `demo@example.com` / `password` |
| Gitea | http://localhost:3100 | `giteaAdmin` / (printed by `ui.sh`) |
| Argo CD | http://localhost:18180 | `admin` / (printed by `ui.sh`) |
| Crossview | http://localhost:9190 | no login |

The pages are the ones in [`../local-demo`](../local-demo) (dashboard, `show.html`,
`demo-flow.html`), so there is one copy to maintain. `ui.sh` serves them with the
re:Invent palette from [`scripts/theme-eks.css`](./scripts/theme-eks.css) and
opens all three. The dashboard polls the cluster through the proxy; the Cards and
Graph views show each `Service` and what the platform produced from it.

`ui.sh` also starts `local-demo/dashboard-server.py` on `127.0.0.1:8012` with
`KUBE_CONTEXT` set to the EKS context, so the **Run the demo** buttons and the
demo flow run the `local-demo/demo/*.sh` scripts against EKS (onboard, existing
service, change tier, FinOps, inspect, reset). It also seeds the `legacy-orders`
example repo into Gitea.

Two steps need a container registry. On EKS they use **private Amazon ECR** in the
current AWS account and region (`DEMO_REGISTRY=ecr`, set by `ui.sh`), not the kind
cluster's Gitea registry:

- **Build and deploy the real image** builds the service's own Dockerfile for
  `linux/amd64` (override with `DEMO_IMAGE_PLATFORM`), pushes it to
  `<account>.dkr.ecr.<region>.amazonaws.com/lockhead/<service>` and commits the image
  to the service repo. The Auto Mode nodes pull it with their node role. There is no
  ingress controller on EKS, so open the app with
  `kubectl port-forward -n team-<team> svc/<service> 8080:80`.
- **Add Observability (Go function)** pushes the Crossplane function package to
  `lockhead/function-observability` in ECR (built on first use by
  `local-demo/packages/4-observability/function/build.sh`, or run it ahead of the
  talk with `DEMO_REGISTRY=ecr`) and installs it. Crossplane's package manager cannot
  use the node role, so the step creates an `ecr-registry-creds` pull secret in
  `crossplane-system` from a fresh ECR token. The token lasts 12 hours, so run the step
  within that window after the secret is created.

Both need valid AWS credentials in the shell that runs `ui.sh` (`AWS_PROFILE`,
`aws sso login`) and docker. The function build also needs `go` and the `crossplane`
CLI (the build script installs the CLI if it is missing).

### Portal path (what you show on stage)

Backstage → **Create → "Onboard a new service"** → fill the form (name, team,
language, tier) → **Create**. The template creates a Gitea repo, applies a
`Service` claim, and Crossplane fans it out into an Argo CD Application + the
three downstream registrations.

### Scripted path — apply a service from the CLI (`scripts/apply.sh`)

The "apply stuff for the cloud" option. It does what the portal does, from the
terminal: renders the golden-path skeleton, creates + pushes the Gitea repo, and
applies the `Service` claim to the EKS cluster.

```bash
./scripts/apply.sh checkout storefront          # name team [language] [tier]

# watch it land
kubectl get services.lockhead.cloud -A
kubectl get applications -n argocd
kubectl get configmap -n security-system

# reset so you can run it again
./scripts/reset.sh checkout storefront
```

You can of course still `kubectl apply` a raw `Service` claim yourself, but then
the `<name>` repo with a `chart/` must already exist in Gitea for Argo CD to
deploy — `apply.sh` creates it for you.

### Tear down

```bash
npx cdk destroy --all
```

## Deploy from GitHub Actions

The workflow lives at
[`.github/workflows/idp-eks-deploy.yml`](../../../.github/workflows/idp-eks-deploy.yml)
and is **manually triggered** (`workflow_dispatch`) — an EKS cluster should only
be created or destroyed on purpose, never on every push.

1. In GitHub: **Actions → Deploy IDP on EKS → Run workflow**.
2. Pick an **action** (`deploy`, `diff`, or `destroy`) and the **region**.

It reuses the same repo conventions as the blog's `deploy.yml`:

- OIDC auth via `aws-actions/configure-aws-credentials` and the `AWS_ROLE_ARN`
  secret (no long-lived keys).
- Self-hosted CodeBuild runners (`codebuild-Lock128GithubRunners-…`).
- `CDK_DEFAULT_ACCOUNT` / `CDK_DEFAULT_REGION` from the `AWS_ACCOUNT_ID` secret
  and the chosen region.

Required repo secrets (already used by the other workflows): `AWS_ROLE_ARN`,
`AWS_ACCOUNT_ID`.

> The CI role needs permission to create EKS/VPC/IAM resources and to run
> `cdk bootstrap`'s asset uploads. Bootstrap the account/region once (the
> existing [`bootstrap.yml`](../../../.github/workflows/bootstrap.yml) workflow
> does this) before the first `deploy`.

## Configuration

All tunables live under the `idp` key in [`cdk.json`](./cdk.json):

| Key | Default | Meaning |
| --- | --- | --- |
| `clusterName` | `lockheadcloud-idp` | EKS cluster name (also used for subnet discovery tags) |
| `kubernetesVersion` | `1.36` | Must match the bundled kubectl Lambda layer (`v36`). 1.33 and older are in paid extended support. |
| `vpcMaxAzs` | `3` | AZs the VPC spans |
| `vpcNatGateways` | `1` | NAT gateways (1 = cheap single-AZ egress; raise for HA) |

There are no node-sizing knobs: **EKS Auto Mode** provisions and scales compute
automatically. Grant kubectl access with `--context adminPrincipalArn=<arn>`.

### Bumping the Kubernetes version

The kubectl Lambda layer is version-matched to the cluster. To move to a newer
Kubernetes version, install the matching layer package
(`@aws-cdk/lambda-layer-kubectl-vNN`), swap the import in `lib/idp-eks-stack.ts`,
and set `idp.kubernetesVersion` in `cdk.json` accordingly.

## Project layout

```
eks-infrastructure/
├── bin/eks-infrastructure.ts     # CDK app entry — wires the two stacks
├── lib/
│   ├── idp-vpc-stack.ts          # VPC + subnets + ELB discovery tags
│   ├── idp-eks-stack.ts          # EKS Auto Mode cluster (eks-v2) + IRSA + access
│   ├── platform-bootstrap.ts     # Crossplane + Argo CD + Crossview + StorageClass + Service API
│   ├── idp-portal.ts             # Gitea + repo-seed Job + ArgoCD apps + Backstage
│   ├── backstage-manifests.ts    # Backstage + Dex + Postgres (ported from install.yaml)
│   ├── argocd-capability-option.ts # OPTIONAL managed EKS Argo CD capability (not wired in)
│   └── yaml-loader.ts            # loads the local-demo platform manifests verbatim
├── scripts/
│   ├── ui.sh                     # port-forwards + serves the live dashboard (cloud)
│   ├── kubeconfig.sh             # own kubeconfig file ~/.kube/<cluster> (sourced by the scripts)
│   ├── apply.sh                  # onboard a service from the CLI (scripted golden path)
│   ├── reset.sh                  # remove an onboarded service to re-run
│   ├── theme-eks.css             # re:Invent palette applied over local-demo's pages
│   └── dashboard.html            # superseded: ui.sh now serves local-demo's pages
├── test/idp-eks.test.ts          # CDK assertion tests
├── cdk.json                      # app config + "idp" context tunables
├── package.json
└── tsconfig.json
```

## Argo CD: self-hosted vs the managed EKS capability

This app runs **self-hosted Argo CD** (Helm). AWS also offers a fully managed
[EKS Capability for Argo CD](https://docs.aws.amazon.com/eks/latest/userguide/argocd.html),
which this app does **not** use, on purpose:

- The `service-onboarding` Composition creates **in-cluster** `argoproj.io`
  `Application` objects — and the on-stage story is literally "watch the
  platform create an Argo CD Application right here". The managed capability
  runs Argo CD's control plane **off** your cluster, so that model would need
  reworking.
- The managed capability **requires IAM Identity Center** for login, versus the
  `admin` + port-forward flow the demo (and dashboard) use.

For when you do want the managed route, [`lib/argocd-capability-option.ts`](./lib/argocd-capability-option.ts)
is a ready-to-flip `CfnCapability` example (needs your IdC instance ARN + admin
group id, and dropping the self-hosted Argo CD Helm chart).

The full managed variant (managed Argo CD + kro + ACK, CodeCommit instead of
Gitea, Backstage on top) is a separate CDK app in
[`../eks-infrastructure-managed`](../eks-infrastructure-managed). It shares no
infrastructure with this one: different stack, cluster, VPC and export names,
and its own CDK bootstrap stack (`CDKToolkit-ManagedIdp`, qualifier `mgdidp`)
instead of this app's `CDKToolkit`. So it can be deployed next to this one,
also in the same account and region. Its README lists what the two
share (Lambda concurrency during deploys, account quotas) and the localhost
ports its portal uses (`7108`/`5657` instead of `7107`/`5656`).

## Notes / differences from the local demo

- **EKS Auto Mode:** no node group, no managed add-ons, no EBS CSI IRSA role —
  AWS manages compute/storage/networking. You just declare workloads.
- **No idpbuilder:** locally, idpbuilder provides the kind cluster + Argo CD +
  Gitea baseline. On EKS there's no idpbuilder, so this app installs each piece
  itself (Gitea via Helm, the platform-api repo via a seed Job) at the same
  in-cluster addresses the existing manifests expect.
- **Identity:** the local demo binds `provider-kubernetes` to `cluster-admin`
  with `InjectedIdentity`. This keeps the same `in-cluster` `ProviderConfig` and
  broad RBAC for demo parity; for a hardened platform you'd scope the provider's
  ClusterRole down and use IRSA for any AWS-touching controllers.
- **URLs:** the portal UIs are reached via `kubectl port-forward` (as in
  `scripts/ui.sh`), so the `localhost`-based Backstage `baseUrl` and Dex issuer
  work unchanged. No LoadBalancer/DNS/cert wiring is needed for the demo.
- **Storage:** Gitea and Backstage's Postgres use EBS-backed PVCs via a default
  `gp3` StorageClass bound to the **Auto Mode** provisioner
  `ebs.csi.eks.amazonaws.com` (local uses kind's hostpath).
- **No proxy self-heal:** the kind DNS / Zscaler-CA workarounds in `start.sh`
  are local-only; EKS nodes pull images over the VPC's NAT egress.
- **Argo CD** is installed `server.insecure=true`, matching the local
  `--insecure` patch — fine for a demo, not for production.
