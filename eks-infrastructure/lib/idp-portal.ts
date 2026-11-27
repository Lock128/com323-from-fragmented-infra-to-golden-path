import * as path from 'path';
import * as fs from 'fs';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';

export interface IdpPortalProps {
  readonly cluster: eks.Cluster;
  /** Directory holding the local-demo packages (platform API + backstage). */
  readonly packagesDir: string;
  /**
   * Resources the portal must wait for: Crossplane/Argo CD/XRD/Composition from
   * the platform baseline. Passed so we can order the repo-seed + ArgoCD apps
   * after the Service API exists.
   */
  readonly dependsOn: Construct[];
}

/**
 * Installs the developer-facing portal stack onto the EKS cluster — the AWS
 * equivalent of what idpbuilder provides locally (Gitea) plus start.sh's
 * install_backstage and setup_gitops.sh:
 *
 *   - Gitea (Helm, PVC-backed) at the SAME in-cluster address the local demo
 *     uses (my-gitea-http.gitea.svc.cluster.local:3000), with admin
 *     "giteaAdmin" and a generated password in secret gitea/gitea-credential.
 *   - A Job that seeds the "platform-api" Gitea repo (XRD + Composition +
 *     Backstage catalog + service-template) — the host-side git push that
 *     setup_gitops.sh does locally, moved into the cluster.
 *   - The two platform ArgoCD Applications (platform-xrds, platform-compositions)
 *     that sync that repo, plus the Argo CD repository credentials secret.
 *   - Backstage + Dex + Postgres (adapted from packages/5-backstage/install.yaml).
 *
 * URL model: identical to the local demo. The operator reaches the UIs via
 * `kubectl port-forward` (Gitea :3100->3000, Backstage :7107->7007,
 * Dex :5656->5656, Argo CD :18180->80) exactly like ui.sh — so every
 * localhost-based URL baked into the Backstage config and Dex issuer works
 * unchanged. No LoadBalancer/DNS/cert wiring needed for the demo.
 */
export class IdpPortal extends Construct {
  constructor(scope: Construct, id: string, props: IdpPortalProps) {
    super(scope, id);
    const { cluster, packagesDir } = props;

    // ── gitea namespace + admin credential secret ────────────────────────
    const giteaNs = cluster.addManifest('GiteaNamespace', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: 'gitea' },
    });

    // The local demo reads secret gitea/gitea-credential (keys: username,
    // password). idpbuilder generates it; on EKS we create it with a fixed demo
    // password so the seed Job + Backstage + Argo CD all agree. For a non-demo
    // cluster you'd source this from Secrets Manager instead of a literal.
    const giteaUsername = 'giteaAdmin';
    const giteaPassword = 'Giteademo-2026!';
    const giteaCredential = cluster.addManifest('GiteaCredential', {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: 'gitea-credential', namespace: 'gitea' },
      type: 'Opaque',
      stringData: { username: giteaUsername, password: giteaPassword },
    });
    giteaCredential.node.addDependency(giteaNs);

    // ── Gitea via Helm ───────────────────────────────────────────────────
    // Release name "my-gitea" so the service is "my-gitea-http" — the exact
    // host the existing manifests reference. Single bundled Postgres, no valkey
    // (Gitea falls back to in-memory cache/session/queue), PVC-backed repos.
    const gitea = cluster.addHelmChart('Gitea', {
      chart: 'gitea',
      repository: 'https://dl.gitea.com/charts/',
      namespace: 'gitea',
      createNamespace: false,
      release: 'my-gitea',
      version: '12.7.0',
      values: {
        'redis-cluster': { enabled: false },
        'valkey-cluster': { enabled: false },
        valkey: { enabled: false },
        // No database subchart: the chart's bundled PostgreSQL uses
        // "bitnamilegacy" images (frozen, no updates). SQLite on the PVC is
        // enough for a single-replica demo Gitea.
        'postgresql-ha': { enabled: false },
        postgresql: { enabled: false },
        persistence: { enabled: true, size: '5Gi' },
        service: { http: { type: 'ClusterIP', port: 3000 } },
        gitea: {
          admin: {
            username: giteaUsername,
            password: giteaPassword,
            email: 'giteaAdmin@demo.local',
          },
          config: {
            server: {
              // In-cluster clients (Argo CD, Backstage) and the seed Job all
              // talk to this host, so advertise it as the clone/root URL.
              ROOT_URL: 'http://my-gitea-http.gitea.svc.cluster.local:3000',
            },
            database: { DB_TYPE: 'sqlite3' },
            cache: { ADAPTER: 'memory' },
            session: { PROVIDER: 'memory' },
            queue: { TYPE: 'level' },
          },
        },
      },
      wait: true,
      timeout: cdk.Duration.minutes(10),
    });
    gitea.node.addDependency(giteaNs);

    // ── Seed the platform-api Gitea repo (replaces setup_gitops.sh push) ──
    // Ship the platform-api files to the Job via a ConfigMap built from the
    // local-demo packages, then a Job git-pushes them into a new Gitea repo.
    const seedFiles = this.collectPlatformApiFiles(packagesDir);
    const seedConfigMap = cluster.addManifest('PlatformApiSeedFiles', {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'platform-api-seed', namespace: 'gitea' },
      // ConfigMap keys can't contain "/", so we flatten paths with "__" and the
      // Job script expands them back into directories before committing.
      data: seedFiles,
    });
    seedConfigMap.node.addDependency(giteaNs);

    const seedJob = cluster.addManifest('PlatformApiSeedJob', {
      apiVersion: 'batch/v1',
      kind: 'Job',
      metadata: { name: 'platform-api-seed', namespace: 'gitea' },
      spec: {
        backoffLimit: 10,
        template: {
          spec: {
            restartPolicy: 'OnFailure',
            containers: [
              {
                name: 'seed',
                image: 'alpine/git:latest',
                env: [
                  {
                    name: 'GITEA_USER',
                    valueFrom: {
                      secretKeyRef: { name: 'gitea-credential', key: 'username' },
                    },
                  },
                  {
                    name: 'GITEA_PASS',
                    valueFrom: {
                      secretKeyRef: { name: 'gitea-credential', key: 'password' },
                    },
                  },
                ],
                command: ['/bin/sh', '-c', SEED_SCRIPT],
                volumeMounts: [{ name: 'seed', mountPath: '/seed' }],
              },
            ],
            volumes: [
              { name: 'seed', configMap: { name: 'platform-api-seed' } },
            ],
          },
        },
      },
    });
    seedJob.node.addDependency(gitea);
    seedJob.node.addDependency(seedConfigMap);

    // ── Register Gitea with Argo CD + create the platform ArgoCD apps ─────
    for (const dep of props.dependsOn) {
      seedJob.node.addDependency(dep);
    }

    const argoRepoSecret = cluster.addManifest('ArgoGiteaRepoSecret', {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'gitea-repos',
        namespace: 'argocd',
        labels: { 'argocd.argoproj.io/secret-type': 'repository' },
      },
      type: 'Opaque',
      stringData: {
        type: 'git',
        url: 'http://my-gitea-http.gitea.svc.cluster.local:3000',
        username: giteaUsername,
        password: giteaPassword,
      },
    });
    for (const dep of props.dependsOn) {
      argoRepoSecret.node.addDependency(dep);
    }

    const xrdApp = cluster.addManifest(
      'PlatformXrdsApp',
      this.loadGitopsApp(packagesDir, 'platform-xrds-app.yaml'),
    );
    const compApp = cluster.addManifest(
      'PlatformCompositionsApp',
      this.loadGitopsApp(packagesDir, 'platform-compositions-app.yaml'),
    );
    xrdApp.node.addDependency(seedJob);
    xrdApp.node.addDependency(argoRepoSecret);
    compApp.node.addDependency(seedJob);
    compApp.node.addDependency(argoRepoSecret);

    // ── Backstage + Dex + Postgres ───────────────────────────────────────
    new BackstageInstall(this, 'Backstage', {
      cluster,
      giteaUsername,
      giteaPassword,
      dependsOn: [gitea, ...props.dependsOn],
    });
  }

  /**
   * Reads the platform-api manifests + Backstage catalog/template that need to
   * live in the seeded Gitea repo, keyed by a "/"-free path the Job expands.
   */
  private collectPlatformApiFiles(packagesDir: string): Record<string, string> {
    const files: Record<string, string> = {};
    const add = (repoPath: string, absPath: string) => {
      files[repoPath.replace(/\//g, '__')] = fs.readFileSync(absPath, 'utf8');
    };

    // Everything under packages/2-platform-api (XRDs, the downstream CRDs the
    // Composition fans out into, and the Composition), under the same layout the
    // ArgoCD apps point at. Walking the tree keeps this in step with local-demo.
    this.walk(path.join(packagesDir, '2-platform-api'), path.dirname(packagesDir), add);
    // Backstage catalog entry + the golden-path templates (new service, existing service).
    const backstageDir = path.join(packagesDir, '5-backstage');
    add('catalog-info.yaml', path.join(backstageDir, 'catalog-info.yaml'));
    this.walk(path.join(backstageDir, 'service-template'), backstageDir, add);
    this.walk(path.join(backstageDir, 'existing-service-template'), backstageDir, add);
    return files;
  }

  /** Recursively add every file under dir, keyed by its path relative to base. */
  private walk(
    dir: string,
    base: string,
    add: (repoPath: string, absPath: string) => void,
  ): void {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        this.walk(abs, base, add);
      } else {
        add(path.relative(base, abs), abs);
      }
    }
  }

  private loadGitopsApp(
    packagesDir: string,
    file: string,
  ): Record<string, unknown> {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { loadManifest } = require('./yaml-loader');
    return loadManifest(path.join(packagesDir, '4-gitops', file));
  }
}

/**
 * Job script: reconstructs the platform-api repo from the flattened ConfigMap,
 * creates the repo in Gitea (idempotent), and force-pushes it on main.
 */
const SEED_SCRIPT = `
set -eu
echo "Waiting for Gitea API..."
i=0
until wget -q -O /dev/null "http://my-gitea-http.gitea.svc.cluster.local:3000/api/v1/version"; do
  i=$((i+1)); [ "$i" -gt 60 ] && echo "Gitea did not become ready" && exit 1
  sleep 5
done

WORK=$(mktemp -d)
# Expand flattened ConfigMap keys (dir__file) back into real paths.
for f in /seed/*; do
  name=$(basename "$f")
  rel=$(echo "$name" | sed 's#__#/#g')
  dest="$WORK/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done

# Create the repo (409 if it already exists — fine).
wget -q -O /dev/null --header="Content-Type: application/json" \
  --post-data='{"name":"platform-api","auto_init":false,"default_branch":"main"}' \
  "http://\${GITEA_USER}:\${GITEA_PASS}@my-gitea-http.gitea.svc.cluster.local:3000/api/v1/user/repos" || true

cd "$WORK"
git init -b main
git config user.email demo@example.com
git config user.name Demo
git add .
git commit -m "Platform API: Service XRD + Composition + golden-path template"
git remote add origin "http://\${GITEA_USER}:\${GITEA_PASS}@my-gitea-http.gitea.svc.cluster.local:3000/\${GITEA_USER}/platform-api.git"
git push -f origin main
echo "platform-api repo seeded."
`;

interface BackstageInstallProps {
  readonly cluster: eks.Cluster;
  readonly giteaUsername: string;
  readonly giteaPassword: string;
  readonly dependsOn: Construct[];
}

/**
 * Backstage + Dex + Postgres, adapted from packages/5-backstage/install.yaml.
 * Reuses the CNOE backstage-app image (includes cnoe:kubernetes:apply) and the
 * same localhost-based URLs — the operator port-forwards to reach the UI, so
 * the Dex issuer and Backstage baseUrl match what the browser hits, exactly as
 * in the local demo.
 */
class BackstageInstall extends Construct {
  constructor(scope: Construct, id: string, props: BackstageInstallProps) {
    super(scope, id);
    const { cluster } = props;

    const manifests = require('./backstage-manifests').backstageManifests({
      postgresPassword: 'backstage-demo',
      giteaUsername: props.giteaUsername,
      giteaPassword: props.giteaPassword,
    });

    // One addManifest call = ONE custom resource that applies the manifests in
    // array order (the "backstage" Namespace is first). Creating ~22 separate
    // custom resources instead would flood the kubectl-provider Lambda (the
    // account concurrency limit can be as low as 10) and race the Namespace.
    const applied = cluster.addManifest('Backstage', ...manifests);
    for (const dep of props.dependsOn) {
      applied.node.addDependency(dep);
    }
  }
}
