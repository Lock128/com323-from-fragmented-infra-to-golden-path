/**
 * Backstage + Dex + Postgres for the managed variant, ported from
 * ../eks-infrastructure/lib/backstage-manifests.ts (which is itself ported from
 * local-demo/packages/5-backstage/install.yaml, adapted from the CNOE reference
 * implementation cnoe-io/stacks, Apache License 2.0; see NOTICE).
 *
 * Differences from the Gitea-based portal:
 *  - Git integration is AWS CodeCommit (integrations.awsCodeCommit). Backstage
 *    reads catalog files from CodeCommit console-style URLs with its IRSA role
 *    (codecommit:GetFile/GetFolder). That includes the golden-path template,
 *    which lives in the platform repo (platform/backstage/template.yaml), so
 *    it is changed with git push.
 *  - The template creates the service repo in CodeCommit through a scaffold
 *    Job (portal/scaffold.sh, EKS Pod Identity), because Backstage has no
 *    CodeCommit publish action.
 *  - Applications target the managed Argo CD cluster registration "in-cluster"
 *    (by name; the capability does not accept kubernetes.default.svc).
 *  - The Service it onboards is the kro-composed lockhead.cloud/v1alpha1 Service.
 *  - The new component is registered with catalog:register (optional: true),
 *    because the scaffold Job may not have pushed yet. The catalog picks the
 *    entity up on its next refresh.
 *
 * Same login as before: browser via kubectl port-forward (scripts/ui.sh),
 * demo@example.com / password through Dex.
 */
export interface BackstageOptions {
  readonly postgresPassword: string;
  readonly region: string;
  /** Platform CodeCommit repo that holds backstage/template.yaml. */
  readonly platformRepoName: string;
  /** Skeleton files, keys as produced by loadSkeleton(). */
  readonly skeleton: Record<string, string>;
  readonly scaffoldScript: string;
}

/** Path of the golden-path template inside the platform repo. */
export const TEMPLATE_PATH = 'backstage/template.yaml';

export const BACKSTAGE_NAMESPACE = 'backstage';
export const BACKSTAGE_SERVICE_ACCOUNT = 'backstage';

/**
 * Browser-facing localhost ports (scripts/ui.sh port-forwards them). They are
 * one higher than the self-hosted variant's 7107/5656, so both portals can be
 * open at the same time. Backstage and Dex bake these into their URLs.
 */
export const BACKSTAGE_LOCAL_PORT = 7108;
export const DEX_LOCAL_PORT = 5657;
export const SCAFFOLDER_SERVICE_ACCOUNT = 'repo-scaffolder';

/**
 * Console-style CodeCommit URL, the only format Backstage's AwsCodeCommitUrlReader
 * accepts: https://<region>.console.aws.amazon.com/codesuite/codecommit/repositories/<repo>/browse/<ref>/--/<path>
 */
export function codeCommitBrowseUrl(region: string, repo: string, filePath: string, ref = 'refs/heads/main'): string {
  return `https://${region}.console.aws.amazon.com/codesuite/codecommit/repositories/${repo}/browse/${ref}/--/${filePath}`;
}

const appConfig = (region: string, templateUrl: string) => `app:
  title: re:Invent 2026 — Platform Demo (managed)
  baseUrl: http://localhost:${BACKSTAGE_LOCAL_PORT}
organization:
  name: Platform Engineering
backend:
  baseUrl: http://localhost:${BACKSTAGE_LOCAL_PORT}
  listen:
    port: 7007
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: http://localhost:${BACKSTAGE_LOCAL_PORT}
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true
  database:
    client: pg
    pluginDivisionMode: schema
    connection:
      host: \${POSTGRES_HOST}
      port: \${POSTGRES_PORT}
      database: \${POSTGRES_DB}
      user: \${POSTGRES_USER}
      password: \${POSTGRES_PASSWORD}
  cache:
    store: memory
integrations:
  awsCodeCommit:
    # Credentials: default AWS chain, i.e. the IRSA role on the backstage SA.
    - region: ${region}
auth:
  environment: development
  session:
    secret: demo-session-secret-local-only
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
    keycloak-oidc:
      development:
        metadataUrl: http://localhost:${DEX_LOCAL_PORT}/.well-known/openid-configuration
        clientId: backstage
        clientSecret: backstage-dex-secret
        additionalScopes: ['profile', 'email']
        prompt: auto
        signIn:
          resolvers:
            - resolver: preferredUsernameMatchingUserEntityName
              dangerouslyAllowSignInWithoutUserInCatalog: true
scaffolder:
  defaultAuthor:
    name: backstage-scaffolder
    email: scaffolder@demo.local
catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template]
  locations:
    # The golden-path template, read from the platform CodeCommit repo.
    - type: url
      target: ${templateUrl}
      rules:
        - allow: [Template]
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc.cluster.local
          name: local
          authProvider: serviceAccount
          # cnoe:kubernetes:apply builds its own kubeconfig from this entry and
          # needs the backstage SA token (K8S_SA_TOKEN).
          serviceAccountToken: \${K8S_SA_TOKEN}
          skipTLSVerify: true
          skipMetricsLookup: true
argocd:
  appLocatorMethods:
    - type: config
      instances: []
`;

const DEX_CONFIG = `issuer: http://localhost:${DEX_LOCAL_PORT}
storage:
  type: memory
web:
  http: 0.0.0.0:5656
oauth2:
  skipApprovalScreen: true
  responseTypes:
    - code
staticClients:
  - id: backstage
    name: Backstage
    secret: backstage-dex-secret
    redirectURIs:
      - http://localhost:${BACKSTAGE_LOCAL_PORT}/api/auth/keycloak-oidc/handler/frame
enablePasswordDB: true
staticPasswords:
  - email: demo@example.com
    hash: "$2a$10$U984wcFfVOR/U3oeP/p2eO9kg3dOEz17gFYeUHS4RQldiAcozphdK"
    username: demo
    userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
`;

export function backstageManifests(opts: BackstageOptions): Record<string, unknown>[] {
  const ns = BACKSTAGE_NAMESPACE;
  const bind = (name: string, kind: 'ClusterRoleBinding' | 'RoleBinding', roleKind: string) => ({
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind,
    metadata: kind === 'RoleBinding' ? { name, namespace: ns } : { name },
    roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: roleKind, name },
    subjects: [{ kind: 'ServiceAccount', name: 'backstage', namespace: ns }],
  });

  return [
    // The namespace and the backstage ServiceAccount (IRSA) are created by
    // ManagedPortal before these manifests.
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'backstage-k8s-sa-token',
        namespace: ns,
        annotations: { 'kubernetes.io/service-account.name': 'backstage' },
      },
      type: 'kubernetes.io/service-account-token',
    },
    // The scaffold Job's identity; mapped to an IAM role through EKS Pod Identity.
    {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: { name: SCAFFOLDER_SERVICE_ACCOUNT, namespace: ns },
    },
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: { name: 'backstage-read-all' },
      rules: [{ apiGroups: ['*'], resources: ['*'], verbs: ['get', 'list', 'watch'] }],
    },
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: { name: 'backstage-onboarding' },
      rules: [
        {
          apiGroups: ['lockhead.cloud'],
          resources: ['services'],
          verbs: ['create', 'patch', 'update', 'get', 'list', 'watch', 'delete'],
        },
        { apiGroups: [''], resources: ['namespaces'], verbs: ['create', 'get', 'list', 'patch'] },
        {
          apiGroups: ['argoproj.io'],
          resources: ['applications'],
          verbs: ['create', 'patch', 'update', 'get', 'list', 'watch', 'delete'],
        },
      ],
    },
    // Scaffold Jobs only in the backstage namespace.
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: { name: 'backstage-scaffold-jobs', namespace: ns },
      rules: [
        {
          apiGroups: ['batch'],
          resources: ['jobs'],
          verbs: ['create', 'patch', 'update', 'get', 'list', 'watch', 'delete'],
        },
      ],
    },
    bind('backstage-read-all', 'ClusterRoleBinding', 'ClusterRole'),
    bind('backstage-onboarding', 'ClusterRoleBinding', 'ClusterRole'),
    bind('backstage-scaffold-jobs', 'RoleBinding', 'Role'),
    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'service-skeleton', namespace: ns },
      data: opts.skeleton,
    },
    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'repo-scaffolder', namespace: ns },
      data: { 'scaffold.sh': opts.scaffoldScript },
    },
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: 'backstage-env-vars', namespace: ns },
      type: 'Opaque',
      stringData: {
        POSTGRES_HOST: 'postgresql.backstage.svc.cluster.local',
        POSTGRES_PORT: '5432',
        POSTGRES_DB: 'backstage',
        POSTGRES_USER: 'backstage',
        POSTGRES_PASSWORD: opts.postgresPassword,
      },
    },
    // PostgreSQL (PVC on the gp3 default StorageClass).
    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: 'postgresql', namespace: ns, labels: { app: 'postgresql' } },
      spec: { clusterIP: 'None', ports: [{ name: 'postgres', port: 5432 }], selector: { app: 'postgresql' } },
    },
    {
      apiVersion: 'apps/v1',
      kind: 'StatefulSet',
      metadata: { name: 'postgresql', namespace: ns, labels: { app: 'postgresql' } },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: 'postgresql' } },
        serviceName: 'postgresql',
        template: {
          metadata: { labels: { app: 'postgresql' } },
          spec: {
            containers: [
              {
                name: 'postgres',
                image: 'docker.io/library/postgres:15.3-alpine3.18',
                ports: [{ containerPort: 5432, name: 'postgresdb' }],
                env: [
                  ...['POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD'].map((key) => ({
                    name: key,
                    valueFrom: { secretKeyRef: { name: 'backstage-env-vars', key } },
                  })),
                  // Postgres will not init in a dir with lost+found.
                  { name: 'PGDATA', value: '/var/lib/postgresql/data/pgdata' },
                ],
                resources: { requests: { cpu: '100m', memory: '256Mi' }, limits: { memory: '500Mi' } },
                volumeMounts: [{ name: 'data', mountPath: '/var/lib/postgresql/data' }],
              },
            ],
          },
        },
        volumeClaimTemplates: [
          {
            metadata: { name: 'data' },
            spec: { accessModes: ['ReadWriteOnce'], resources: { requests: { storage: '2Gi' } } },
          },
        ],
      },
    },
    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'backstage-config', namespace: ns },
      data: {
        'app-config.yaml': appConfig(
          opts.region,
          codeCommitBrowseUrl(opts.region, opts.platformRepoName, TEMPLATE_PATH),
        ),
      },
    },
    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: 'backstage', namespace: ns },
      spec: { ports: [{ name: 'http', port: 7007, targetPort: 'http' }], selector: { app: 'backstage' } },
    },
    {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: 'backstage', namespace: ns },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: 'backstage' } },
        template: {
          metadata: { labels: { app: 'backstage' } },
          spec: {
            serviceAccountName: 'backstage',
            containers: [
              {
                name: 'backstage',
                image: 'ghcr.io/cnoe-io/backstage-app:9232d633b2698fffa6d0a73b715e06640d170162',
                command: ['node', 'packages/backend', '--config', 'config/app-config.yaml'],
                ports: [{ containerPort: 7007, name: 'http' }],
                env: [
                  { name: 'NODE_TLS_REJECT_UNAUTHORIZED', value: '0' },
                  { name: 'LOG_LEVEL', value: 'info' },
                  { name: 'AWS_REGION', value: opts.region },
                  {
                    name: 'K8S_SA_TOKEN',
                    valueFrom: { secretKeyRef: { name: 'backstage-k8s-sa-token', key: 'token' } },
                  },
                ],
                envFrom: [{ secretRef: { name: 'backstage-env-vars' } }],
                volumeMounts: [
                  { name: 'backstage-config', mountPath: '/app/config', readOnly: true },
                ],
                resources: { requests: { cpu: '200m', memory: '512Mi' }, limits: { memory: '1Gi' } },
              },
              {
                // Lets the backend reach Dex at localhost:<DEX_LOCAL_PORT>, the same issuer
                // URL the browser uses through port-forward.
                name: 'dex-proxy',
                image: 'alpine/socat:latest',
                args: [`TCP6-LISTEN:${DEX_LOCAL_PORT},fork,reuseaddr,ipv6only=0`, 'TCP:dex.backstage.svc.cluster.local:5656'],
                resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '32Mi' } },
              },
            ],
            volumes: [
              {
                name: 'backstage-config',
                configMap: { name: 'backstage-config', items: [{ key: 'app-config.yaml', path: 'app-config.yaml' }] },
              },
            ],
          },
        },
      },
    },
    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'dex-config', namespace: ns },
      data: { 'config.yaml': DEX_CONFIG },
    },
    {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: 'dex', namespace: ns, labels: { app: 'dex' } },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: 'dex' } },
        template: {
          metadata: { labels: { app: 'dex' } },
          spec: {
            containers: [
              {
                name: 'dex',
                image: 'ghcr.io/dexidp/dex:v2.39.1',
                command: ['dex', 'serve', '/etc/dex/config.yaml'],
                ports: [{ containerPort: 5656, name: 'http' }],
                volumeMounts: [{ name: 'dex-config', mountPath: '/etc/dex', readOnly: true }],
                resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
              },
            ],
            volumes: [{ name: 'dex-config', configMap: { name: 'dex-config' } }],
          },
        },
      },
    },
    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: 'dex', namespace: ns, labels: { app: 'dex' } },
      spec: { ports: [{ name: 'http', port: 5656, targetPort: 'http' }], selector: { app: 'dex' } },
    },
  ];
}
