/**
 * Backstage + Dex + Postgres manifests for EKS, ported from the local demo's
 * packages/5-backstage/install.yaml, which is adapted from the CNOE reference
 * implementation (cnoe-io/stacks, Apache License 2.0; see NOTICE). Kept as code (not a verbatim YAML load)
 * because the local file relies on two secrets (backstage-env-vars,
 * gitea-credentials) that start.sh creates imperatively — here we inline the
 * same values so the whole thing is declarative and deploys in one pass.
 *
 * The localhost-based URLs (baseUrl, Dex issuer) are intentionally preserved:
 * the operator reaches the UIs via `kubectl port-forward` just like ui.sh does
 * locally (Backstage :7107->7007, Dex :5656->5656), so the browser-facing URLs
 * match and OIDC login works. Login: demo@example.com / password.
 */

export interface BackstageManifestOptions {
  readonly postgresPassword: string;
  readonly giteaUsername: string;
  readonly giteaPassword: string;
}

const APP_CONFIG = `app:
  title: re:Invent 2026 — Platform Demo
  baseUrl: http://localhost:7107
organization:
  name: Platform Engineering

backend:
  baseUrl: http://localhost:7107
  listen:
    port: 7007
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: http://localhost:7107
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
  gitea:
    - baseUrl: http://my-gitea-http.gitea.svc.cluster.local:3000
      host: my-gitea-http.gitea.svc.cluster.local:3000
      username: \${GITEA_USERNAME}
      password: \${GITEA_PASSWORD}

techdocs:
  builder: local
  generator:
    runIn: local
  publisher:
    type: local

auth:
  environment: development
  session:
    secret: demo-session-secret-local-only
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
    keycloak-oidc:
      development:
        metadataUrl: http://localhost:5656/.well-known/openid-configuration
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
  defaultCommitMessage: "backstage scaffolder"

catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template]
  locations:
    - type: url
      target: http://my-gitea-http.gitea.svc.cluster.local:3000/giteaAdmin/platform-api/raw/branch/main/catalog-info.yaml
      rules:
        - allow: [Location, Template]

kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc.cluster.local
          name: local
          authProvider: serviceAccount
          # The cnoe:kubernetes:apply scaffolder action builds its OWN kubeconfig from
          # this entry and requires serviceAccountToken (the backstage SA's token,
          # injected as K8S_SA_TOKEN from the backstage-k8s-sa-token Secret).
          serviceAccountToken: \${K8S_SA_TOKEN}
          skipTLSVerify: true
          skipMetricsLookup: true

argocd:
  appLocatorMethods:
    - type: config
      instances: []
`;

const DEX_CONFIG = `issuer: http://localhost:5656

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
      - http://localhost:7107/api/auth/keycloak-oidc/handler/frame

enablePasswordDB: true

staticPasswords:
  - email: demo@example.com
    hash: "$2a$10$U984wcFfVOR/U3oeP/p2eO9kg3dOEz17gFYeUHS4RQldiAcozphdK"
    username: demo
    userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
`;

export function backstageManifests(
  opts: BackstageManifestOptions,
): Record<string, unknown>[] {
  const ns = 'backstage';

  return [
    { apiVersion: 'v1', kind: 'Namespace', metadata: { name: ns } },

    {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: { name: 'backstage', namespace: ns },
    },

    // Long-lived token for the backstage SA. A Secret of this type is filled in by
    // the control plane; the Deployment reads it as K8S_SA_TOKEN (see APP_CONFIG).
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
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: { name: 'backstage-read-all' },
      rules: [
        { apiGroups: ['*'], resources: ['*'], verbs: ['get', 'list', 'watch'] },
      ],
    },
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: { name: 'backstage-crossplane-apply' },
      rules: [
        {
          apiGroups: ['lockhead.cloud'],
          resources: ['services', 'xservices'],
          verbs: ['create', 'patch', 'update', 'get', 'list', 'watch', 'delete'],
        },
        {
          apiGroups: [''],
          resources: ['namespaces'],
          verbs: ['create', 'get', 'list'],
        },
        // The template's last step creates the per-service Argo CD Application
        // (the GitOps bootstrap that syncs service-claim.yaml).
        {
          apiGroups: ['argoproj.io'],
          resources: ['applications'],
          verbs: ['create', 'patch', 'update', 'get', 'list', 'watch', 'delete'],
        },
      ],
    },
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: { name: 'backstage-read-all' },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'backstage-read-all',
      },
      subjects: [{ kind: 'ServiceAccount', name: 'backstage', namespace: ns }],
    },
    {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: { name: 'backstage-crossplane-apply' },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'backstage-crossplane-apply',
      },
      subjects: [{ kind: 'ServiceAccount', name: 'backstage', namespace: ns }],
    },

    // Config/credentials that start.sh creates imperatively, inlined here.
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
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: 'gitea-credentials', namespace: ns },
      type: 'Opaque',
      stringData: {
        // Same giteaAdmin credential the portal uses — Backstage's publish:gitea
        // and catalog fetch authenticate with it.
        GITEA_USERNAME: opts.giteaUsername,
        GITEA_PASSWORD: opts.giteaPassword,
      },
    },

    // PostgreSQL headless service + StatefulSet (PVC-backed).
    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: 'postgresql', namespace: ns, labels: { app: 'postgresql' } },
      spec: {
        clusterIP: 'None',
        ports: [{ name: 'postgres', port: 5432 }],
        selector: { app: 'postgresql' },
      },
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
                  {
                    name: 'POSTGRES_DB',
                    valueFrom: {
                      secretKeyRef: { name: 'backstage-env-vars', key: 'POSTGRES_DB' },
                    },
                  },
                  {
                    name: 'POSTGRES_USER',
                    valueFrom: {
                      secretKeyRef: { name: 'backstage-env-vars', key: 'POSTGRES_USER' },
                    },
                  },
                  {
                    name: 'POSTGRES_PASSWORD',
                    valueFrom: {
                      secretKeyRef: {
                        name: 'backstage-env-vars',
                        key: 'POSTGRES_PASSWORD',
                      },
                    },
                  },
                  // Postgres refuses to init in a dir with a lost+found; point
                  // PGDATA at a subdir of the EBS-backed mount.
                  { name: 'PGDATA', value: '/var/lib/postgresql/data/pgdata' },
                ],
                resources: {
                  requests: { cpu: '100m', memory: '256Mi' },
                  limits: { memory: '500Mi' },
                },
                volumeMounts: [
                  { name: 'data', mountPath: '/var/lib/postgresql/data' },
                ],
              },
            ],
          },
        },
        volumeClaimTemplates: [
          {
            metadata: { name: 'data' },
            spec: {
              accessModes: ['ReadWriteOnce'],
              resources: { requests: { storage: '2Gi' } },
            },
          },
        ],
      },
    },

    {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: 'backstage-config', namespace: ns },
      data: { 'app-config.yaml': APP_CONFIG },
    },

    {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: 'backstage', namespace: ns },
      spec: {
        ports: [{ name: 'http', port: 7007, targetPort: 'http' }],
        selector: { app: 'backstage' },
      },
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
                image:
                  'ghcr.io/cnoe-io/backstage-app:9232d633b2698fffa6d0a73b715e06640d170162',
                command: [
                  'node',
                  'packages/backend',
                  '--config',
                  'config/app-config.yaml',
                ],
                ports: [{ containerPort: 7007, name: 'http' }],
                env: [
                  { name: 'NODE_TLS_REJECT_UNAUTHORIZED', value: '0' },
                  { name: 'LOG_LEVEL', value: 'info' },
                  {
                    name: 'K8S_SA_TOKEN',
                    valueFrom: {
                      secretKeyRef: { name: 'backstage-k8s-sa-token', key: 'token' },
                    },
                  },
                ],
                envFrom: [
                  { secretRef: { name: 'backstage-env-vars' } },
                  { secretRef: { name: 'gitea-credentials' } },
                ],
                volumeMounts: [
                  { name: 'backstage-config', mountPath: '/app/config', readOnly: true },
                ],
                resources: {
                  requests: { cpu: '200m', memory: '512Mi' },
                  limits: { memory: '1Gi' },
                },
              },
              {
                name: 'dex-proxy',
                image: 'alpine/socat:latest',
                args: [
                  'TCP6-LISTEN:5656,fork,reuseaddr,ipv6only=0',
                  'TCP:dex.backstage.svc.cluster.local:5656',
                ],
                resources: {
                  requests: { cpu: '10m', memory: '16Mi' },
                  limits: { memory: '32Mi' },
                },
              },
            ],
            volumes: [
              {
                name: 'backstage-config',
                configMap: {
                  name: 'backstage-config',
                  items: [{ key: 'app-config.yaml', path: 'app-config.yaml' }],
                },
              },
            ],
          },
        },
      },
    },

    // Dex OIDC provider.
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
                volumeMounts: [
                  { name: 'dex-config', mountPath: '/etc/dex', readOnly: true },
                ],
                resources: {
                  requests: { cpu: '50m', memory: '64Mi' },
                  limits: { memory: '256Mi' },
                },
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
      spec: {
        ports: [{ name: 'http', port: 5656, targetPort: 'http' }],
        selector: { app: 'dex' },
      },
    },
  ];
}
