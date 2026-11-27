# IDP-on-EKS, fully managed (CDK)

The alternative to [`../eks-infrastructure`](../eks-infrastructure) shown on the
**"Appendix: fully managed"** slide. The developer-facing `Service` API is the
same. The plumbing underneath is different:

| Slide box | Here | Self-hosted variant |
| --- | --- | --- |
| Argo CD | **EKS Capability for Argo CD** (AWS runs it) | Argo CD Helm chart |
| kro | **EKS Capability for kro** composes the `Service` API (`ResourceGraphDefinition`) | Crossplane XRD + Composition |
| ACK | **EKS Capability for ACK** creates AWS resources (an ECR repo per service) | not present |
| EKS Auto Mode | same | same |
| Git host | **CodeCommit** in the same account (or any external host) | in-cluster Gitea |
| Portal | Backstage + Dex, template creates repos in CodeCommit | Backstage + Dex, template publishes to Gitea |

## Requirements

Before the first deploy:

- [ ] Node.js 24 and AWS CLI v2.
- [ ] This app's **own CDK bootstrap stack** `CDKToolkit-ManagedIdp`
      (qualifier `mgdidp`) in the target region (**`us-west-2`**,
      `managedIdp.region`). `scripts/deploy.sh` creates it on the first
      deploy. It does not use the default `CDKToolkit` of the self-hosted
      variant.
- [ ] **EKS Capabilities** and **CodeCommit** are available in that region.
- [ ] **IAM Identity Center** values in `cdk.local.json` (set `idcInstanceArn`,
      `idcRegion` and an admin user or group, see
      [Identity Center](#identity-center)). Managed Argo CD has no local login.
- [ ] Free quota in the region: 1 VPC and 1 Elastic IP for the NAT gateway
      (the default limit is 5 of each per region).
- [ ] Don't deploy at the same time as the self-hosted stacks in the same
      region (see [Lambda concurrency](#running-next-to-the-self-hosted-variant)).
      `scripts/deploy.sh` refuses to start while one is in progress.
- [ ] An IAM principal for kubectl (`adminPrincipalArn`), e.g. your SSO role.
- [ ] For changing the golden path: [local CodeCommit access](#local-codecommit-access)
      (`./scripts/codecommit-setup.sh`).

## Running next to the self-hosted variant

The two apps share no infrastructure, so you can deploy both into one account
and region, and deploy, change or delete either one without affecting the other.
`test/isolation.test.ts` checks the managed side of this table:

| | Self-hosted (`../eks-infrastructure`) | Managed (this app) |
| --- | --- | --- |
| Stacks | `IdpVpcStack`, `IdpEksStack` | `ManagedIdpVpcStack`, `ManagedIdpEksStack` |
| CDK bootstrap | `CDKToolkit` (qualifier `hnb659fds`) | `CDKToolkit-ManagedIdp` (qualifier `mgdidp`) |
| Cluster | `lockheadcloud-idp` | `lockheadcloud-managed` |
| Region | `us-west-2` (`deploy.sh`) | `us-west-2` (`cdk.json`) |
| VPC CIDR | `10.40.0.0/16` | `10.41.0.0/16` |
| CloudFormation exports | `IdpVpcId`, `IdpClusterName` | `ManagedIdpVpcId`, `ManagedIdpClusterName` |
| Git | Gitea inside the cluster | CodeCommit repos `lockheadcloud-managed-platform`, `svc-*` |
| Portal on localhost | Backstage `:7107`, Dex `:5656` | Backstage `:7108`, Dex `:5657` |
| Dashboard on localhost | `:8011`, backend `:8012` | `:8021`, backend `:8022` (read-only) |
| `scripts/ui.sh` kubeconfig | own file `~/.kube/lockheadcloud-idp` | own file `~/.kube/lockheadcloud-managed` |

The bootstrap separation means each app has its own assets bucket
(`cdk-mgdidp-assets-<account>-<region>` vs `cdk-hnb659fds-assets-...`), assets
ECR repo, and deploy/publishing roles. IAM roles, security groups, the OIDC
provider, the kubectl Lambda and the EKS log group are created per stack or per
cluster. Neither app imports a CloudFormation export of the other.

What is account-wide by AWS design and can't be separated (no infrastructure
of either app, but limits both count against):

- **Lambda concurrency.** Accounts with a low Lambda concurrency limit (for
  example 10 in a new or sandbox account) can run only a few steps at once. Each kubectl/custom-resource step holds about 2
  while it runs, and each stack runs its own steps one at a time. So run **one
  deploy (or destroy) at a time**: deploying both apps at once can fail with
  `TooManyRequestsException: Rate Exceeded`. Once deployed, nothing runs on
  Lambda, so the two clusters run side by side without interfering.
- **Regional quotas** (VPCs, Elastic IPs, EKS clusters). Both together use 2
  VPCs and 2 Elastic IPs in `us-west-2`, within the default limits of 5.
- **EKS service-linked roles** (`AWSServiceRoleForAmazonEKS*`). AWS creates
  one per account and uses it for every cluster.

The `examples/` and demo flows are independent too. The managed cluster has
no Crossplane, so the self-hosted `scripts/apply.sh` doesn't apply here.

## Identity Center

Managed Argo CD has no local login, so it needs an IAM Identity Center instance.
The instance can live in another account (for example the organization's
management account) and region than the cluster; the capability takes the
Identity Center region separately (`idcRegion`). Read-only lookups:
```bash
export AWS_PROFILE=<profile with access to Identity Center>
aws sso-admin list-instances --region <idc-region> \
  --query 'Instances[].[InstanceArn,IdentityStoreId]' --output text
aws identitystore list-users --region <idc-region> --identity-store-id <store-id> \
  --query 'Users[].[UserName,UserId]' --output text
aws identitystore list-groups --region <idc-region> --identity-store-id <store-id> \
  --query 'Groups[].[DisplayName,GroupId]' --output text
```
Copy `cdk.local.example.json` to `cdk.local.json` and set `idcInstanceArn`,
`idcRegion` and either `idcAdminUserId` or `idcAdminGroupId`. `cdk.local.json` is
gitignored, so your Identity Center IDs stay out of the repository; its
`managedIdp` keys override the ones in `cdk.json`, for the CDK app and the scripts. To use a group, create one in Identity Center (for
example `argocd-admins`), add users, and set `idcAdminGroupId`. Both can be set.

## Deploy

[`scripts/deploy.sh`](scripts/deploy.sh) wraps the CDK commands, like the
self-hosted variant's `deploy.sh`:

```bash
cd eks-infrastructure-managed
./scripts/deploy.sh            # deploy (default)
./scripts/deploy.sh status     # stack + capability status, Argo CD and repo URLs
./scripts/deploy.sh diff       # what would change
./scripts/deploy.sh kubeconfig # (re)write ~/.kube/lockheadcloud-managed
./scripts/deploy.sh destroy    # full teardown, runs ./scripts/delete.sh
```

`deploy` does the following:

1. Signs in with AWS SSO if the session for
   `default` expired.
2. Looks up your SSO role's IAM ARN and grants it kubectl cluster-admin
   (`adminPrincipalArn`).
3. Preflight: stops if a self-hosted stack (`IdpVpcStack`, `IdpEksStack`)
   has a create/update in progress in the region (Lambda concurrency; a delete is ignored, override
   with `FORCE=1`), checks that CodeCommit is usable, and creates this app's own
   bootstrap stack `CDKToolkit-ManagedIdp` if it doesn't exist yet.
4. Runs `cdk deploy --all`. The first run takes roughly 30 to 40 minutes.
5. Writes the kubeconfig to `~/.kube/lockheadcloud-managed` (your current
   kubectl context stays as it is) and prints the Argo CD and repo URLs.

Overrides: `IDP_AWS_PROFILE`, `MANAGED_IDP_REGION`, `ADMIN_PRINCIPAL_ARN`,
`REQUIRE_APPROVAL` (default `never`; `broadening` prompts on IAM changes),
`FORCE=1`.

Without the script:

```bash
export AWS_PROFILE=<your-profile>
aws sso login --profile <your-profile>
npm ci
# once per region; toolkitStackName and the qualifier are also in cdk.json
npx cdk bootstrap aws://<account-id>/us-west-2 --qualifier mgdidp --toolkit-stack-name CDKToolkit-ManagedIdp
ROLE_NAME=$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)
npx cdk deploy --all \
  -c adminPrincipalArn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
```

Override any `cdk.json` key with `-c managedIdp:<key>=<value>`.

| Key | Default | Meaning |
| --- | --- | --- |
| `region` | `us-west-2` | Deployment region. Explicit, so switching AWS profiles can't move it. The scripts read it too |
| `clusterName` | `lockheadcloud-managed` | EKS cluster name |
| `kubernetesVersion` | `1.36` | Must match the bundled kubectl layer (v36) |
| `gitProvider` | `codecommit` | `codecommit` or `external` |
| `repositoryName` | `lockheadcloud-managed-platform` | Platform CodeCommit repo |
| `externalRepoUrl` | | Required for `external`. The repo must contain the contents of `platform/` and be readable by Argo CD (public, or add a repository secret / CodeConnections) |
| `serviceRepoPrefix` | `svc-` | Name prefix for the per-service CodeCommit repos (also scopes the IAM policies) |
| `portal` | `true` | Install Backstage. Off with `external` |
| `idcInstanceArn`, `idcRegion` | empty (set yours in `cdk.local.json`) | Identity Center instance ARN and its region |
| `idcAdminUserId`, `idcAdminGroupId` | empty (set yours in `cdk.local.json`) | Who gets Argo CD ADMIN. At least one is required |

Then:

```bash
./scripts/ui.sh                      # Backstage http://localhost:7108, prints the Argo CD URL,
                                     # dashboard http://localhost:8021/ui/dashboard.html
export KUBECONFIG=~/.kube/lockheadcloud-managed
kubectl get resourcegraphdefinitions          # service: Active
kubectl get crd | grep -E 'kro|ecr.services'  # capability CRDs
kubectl apply -f examples/service.yaml
kubectl get services.lockhead.cloud -A
```

Sign in to Backstage with `demo@example.com` / `password`, and to Argo CD with
your Identity Center user.

`ui.sh` runs the forwards in the background (it no longer waits for Ctrl-C).
Stop them with `../local-demo/target.sh stop managed`. If `../local-demo` is next
to this app, `ui.sh` also serves its dashboard pages read-only for this cluster:
the live view, the kubectl box and the inspect steps work, and the steps that
need Gitea or Crossplane are disabled. `../local-demo/target.sh` switches between
this cluster, the self-hosted EKS variant and the local kind demo.

## Tear down

```bash
./scripts/delete.sh --dry-run   # show what would be deleted, change nothing
./scripts/delete.sh             # asks you to type the cluster name
./scripts/delete.sh --yes       # no prompt
./scripts/delete.sh --keep-service-repos
```

Like the self-hosted `delete.sh`, it cleans up inside the cluster before
`cdk destroy`, because some resources are not owned by CloudFormation:

1. Deletes the per-service Argo CD apps created by Backstage first, so Argo
   CD's self-heal does not re-apply the Services from Git.
2. Deletes all `Service`s. kro removes their Argo CD apps and registrations,
   and ACK deletes their ECR repos. The script waits for ACK, because the ECR
   repos are only cleaned up while the capability still runs.
3. Deletes LoadBalancer Services and Backstage's workloads and PVCs, so the
   Postgres EBS volume is released.
4. Runs `cdk destroy --all`. This also deletes the platform CodeCommit repo,
   **including anything you pushed to it**. Clone it first if you want to keep
   golden-path changes.
5. Deletes the `svc-*` CodeCommit repos created by the portal. Only repos
   with the prefix **and** the `lockhead.cloud/service` tag that
   `scaffold.sh` sets are deleted; the confirmation prompt lists them.
6. Deletes the EKS log group, and reports (never deletes) leftover
   Kubernetes-created EBS volumes and service ECR repos.
7. Removes `~/.kube/lockheadcloud-managed` and any context for the cluster in
   your default kubeconfig.

It stops while a self-hosted stack has a create/update in progress in the region
(`FORCE=1` overrides). It never touches the self-hosted variant's
`CDKToolkit`. It leaves this app's own `CDKToolkit-ManagedIdp` in place (cheap,
speeds up the next deploy) and prints how to remove it.
Leftover EBS volumes are only reported because both variants may run in the
same region, and tags can't prove which cluster owned a volume.

## What gets deployed

| Stack | Contents |
| --- | --- |
| `ManagedIdpVpcStack` | VPC, public + private subnets, ELB discovery tags |
| `ManagedIdpEksStack` | EKS Auto Mode cluster, platform CodeCommit repo (seeded), the three capabilities with their IAM roles, `in-cluster` registration secret, the `platform-api` Argo CD Application, and the Backstage portal (CodeCommit only) |

Flow after deploy: Argo CD syncs the platform repo. Wave 0 applies the
downstream CRDs and namespaces. Wave 1 applies the kro `Service`
`ResourceGraphDefinition` ([`platform/apis/service-rgd.yaml`](platform/apis/service-rgd.yaml)),
which makes `services.lockhead.cloud` available.

A `Service` (name, team, language, tier, repoURL, repoPath) then produces an Argo
CD Application, an ECR repository (ACK), and the SecurityScan, OnCallRegistration
and ReportingEntry records, with the tier policy mapping from the Crossplane
variant.

## CodeCommit

The Argo CD capability reads CodeCommit natively: its role has
`codecommit:GitPull`, and Applications reference
`https://git-codecommit.<region>.amazonaws.com/v1/repos/<name>`. No Git
credentials or repository secrets exist in the cluster.

CodeCommit was de-emphasized in July 2024 and returned to general availability
([AWS blog](https://aws.amazon.com/blogs/devops/aws-codecommit-returns-to-general-availability/)).
It is not available in every region; check yours, or use `gitProvider=external`.

### The platform repo

- CDK seeds `main` from [`platform/`](platform) **once, when the repo is
  created**. After that the CodeCommit repo is the source of truth and is
  changed with `git push`. Later edits to `platform/` in this folder do not
  reach an existing repo; only a new repo (new name, or after deleting it)
  picks them up.
- Layout: `crds/` and `apis/` are synced to the cluster by Argo CD.
  `backstage/template.yaml` is the Backstage golden-path template. Argo CD
  excludes `backstage/*`, and Backstage reads that file from CodeCommit.
- `platform/backstage/template.yaml` contains placeholders (`@@REGION@@`,
  `@@CLUSTER_NAME@@`, `@@SERVICE_REPO_PREFIX@@`, `@@SCAFFOLD_IMAGE@@`).
  [`lib/platform-seed.ts`](lib/platform-seed.ts) fills them in while staging
  the seed, so the CodeCommit copy holds real values. An unknown placeholder
  fails the synth.
- `cdk destroy` deletes the platform repo, including any commits you pushed.
  The `svc-*` repos created by the portal are not managed by CloudFormation and
  stay.

### Local CodeCommit access

[`scripts/codecommit-setup.sh`](scripts/codecommit-setup.sh) sets up git to
get CodeCommit credentials from the AWS CLI with your SSO profile. It needs no
extra tools and no IAM user.

```bash
./scripts/codecommit-setup.sh          # configure git + verify access
./scripts/codecommit-setup.sh clone    # also clone the platform repo (next to this repository)
./scripts/codecommit-setup.sh check    # show the config + verify, change nothing
./scripts/codecommit-setup.sh remove   # undo
```

It writes three entries to your global git config, scoped to the region's
CodeCommit host only (`https://git-codecommit.us-west-2.amazonaws.com`), and
runs `aws sso login` if your session has expired:

```ini
[credential "https://git-codecommit.us-west-2.amazonaws.com"]
	UseHttpPath = true
	helper =
	helper = !aws --profile default codecommit credential-helper $@
```

The empty `helper =` resets the helper list for that host, so the macOS
keychain is skipped. The keychain would cache the temporary credentials, and
git would fail with `403` once they expire. Other git hosts keep using the
keychain.

Overrides: `CODECOMMIT_PROFILE` (default `$AWS_PROFILE`, else `default`) and `MANAGED_IDP_REGION` (default from
`cdk.json`). An administrator role already has
`codecommit:GitPull`/`GitPush`; a narrower role needs those two actions on
the repos.

Alternative without the git config: [`git-remote-codecommit`](https://github.com/aws/git-remote-codecommit)
(`pipx install git-remote-codecommit`), then
`git clone codecommit::us-west-2://default@lockheadcloud-managed-platform`.
It needs Python.

To change the golden path:

```bash
cd ../../lockheadcloud-managed-platform   # cloned next to this repository
$EDITOR backstage/template.yaml
git commit -am "golden path: ..." && git push
```

Backstage picks up the change on its next catalog refresh (a few minutes).
Pushes to `crds/` or `apis/` are synced by Argo CD.

## Backstage portal

Same "Onboard a new service" form as the Gitea variant (name, team, language,
tier). Backstage has no CodeCommit publish action, and ACK has no CodeCommit
controller, so the template runs these steps:

1. Starts a Job (`scaffold-<name>` in `backstage`) running
   [`portal/scaffold.sh`](portal/scaffold.sh) in the `aws-cli` image. It creates
   the CodeCommit repo `svc-<name>` and commits the rendered golden-path
   skeleton (from `local-demo/.../service-template/skeleton`) as the first
   commit. The Job gets AWS access through EKS Pod Identity, with a role
   limited to `codecommit:*` actions on `svc-*`.
2. Creates the `team-<team>` namespace.
3. Creates the Argo CD Application `svc-<name>`, which syncs only
   `service-claim.yaml` from the new repo. Argo CD applies the `Service`, and
   kro composes the rest. The app retries until the Job has pushed.
4. Registers `catalog-info.yaml` from the new repo in the Backstage catalog.
   The step uses `optional: true` because the Job may not have pushed yet.
   The location is saved anyway, and the component appears on the next catalog
   refresh (a few minutes).

### How Backstage reads CodeCommit

Backstage includes a CodeCommit URL reader (`integrations.awsCodeCommit`), and
the pinned CNOE image ships it. It only accepts console-style URLs:

```
https://<region>.console.aws.amazon.com/codesuite/codecommit/repositories/<repo>/browse/refs/heads/main/--/<path>
```

It calls `codecommit:GetFile` / `GetFolder` with the default AWS credential
chain. The `backstage` service account uses **IRSA**, not Pod Identity: the AWS
SDK in that image (credential-providers 3.502) predates Pod Identity, but does
support IRSA web identity tokens. Its role can read the platform repo and the
`svc-*` repos. The scaffold Job keeps Pod Identity, because its newer `aws-cli`
image supports it.

The reader can read files but cannot create repos or push, so the Job is still
needed for publishing.

## Limitations

Compared with the self-hosted variant:

- **No CI and no app image.** The skeleton's Gitea Actions pipeline is dropped
  and nothing builds images, so services deploy the chart's nginx fallback
  page. ACK creates an ECR repo per service, but nothing pushes to it yet.
- **No Ingress.** The skeleton's nginx Ingress is disabled; the cluster has no
  ingress-nginx. Reach a service with `kubectl port-forward`.
- **Skeleton and `scaffold.sh` are ConfigMaps.** Unlike the template, changing
  them needs a CDK redeploy.
- **New components appear with a delay** (next catalog refresh), and the
  Argo CD app for a new service shows errors until the scaffold Job has pushed.
- **No Argo CD link with the real URL** in the onboarding output: the URL only
  exists after deploy, so the template links the EKS console cluster page.
  `scripts/ui.sh` prints the real URL.
- **Not ported:** the "onboard an existing service" template, Crossview, the
  live dashboard, and the `apply.sh`/`reset.sh` scripts. No GitHub
  Actions workflow deploys this app.

Permissions (demo-grade):

- Argo CD and kro get `AmazonEKSClusterAdminPolicy` on the cluster. EKS creates
  their access entries itself, so the policy is attached with an SDK call
  (custom resource) instead of `AWS::EKS::AccessEntry`.
- The ACK role carries ECR permissions directly (simple model, single account).
  For several teams or accounts, switch to IAM Role Selectors.
- Literal demo passwords (Postgres, Dex user, Backstage session secret), as in
  the self-hosted variant.
- Capabilities use `deletePropagationPolicy: RETAIN`, the only supported value.
  Destroying the stack leaves the Kubernetes resources they created behind
  with the cluster, and ACK-created ECR repositories are not deleted.

## Not verified yet

- **Not deployed.** The stacks synthesize and
  pass the unit tests. The RGD has not run against the managed kro. Points to
  check on first deploy: that the managed kro version accepts `schema.group`
  and a `metadata.namespace` that differs from the instance namespace (the
  Application goes to `argocd`, the registrations to their system namespaces),
  and the ECR `readyWhen` condition.
- **Cross-account Identity Center.** The instance belongs to the management
  account and the cluster runs in a member account. Organization instances are
  meant to be used from member accounts, but this is not confirmed with the
  Argo CD capability. If capability creation fails on Identity Center, check
  this first.
- **Argo CD `exclude: backstage/*`** is in the synthesized Application but has
  not run against the managed Argo CD.
- **Backstage CodeCommit reads.** Checked inside the pinned Backstage image:
  the reader is registered, matches the template's URLs, and uses IRSA
  web-identity credentials (a dummy token got rejected by STS). A real read
  with the IRSA role has not run.
- **Scaffold Job.** Tested in the pinned `aws-cli` image with a stubbed `aws`
  command (13 files rendered, input validation). The real CodeCommit calls
  and Pod Identity have not run.
- **`delete.sh`** ran as `--dry-run` in `us-west-2` (no managed
  stacks yet): repo discovery, the parallel-operation guard, the leftover
  reports and the confirmation prompt work. The in-cluster cleanup has not run,
  since it needs a deployed cluster.
- **Local CodeCommit access**: `codecommit-setup.sh` is tested in
  `us-west-2` with a throwaway git config (setup, check,
  clone, remove; authentication works). Cloning waits for the deploy, since the
  platform repo does not exist yet.

```bash
npm test   # synth-level assertions, no AWS access needed
```
