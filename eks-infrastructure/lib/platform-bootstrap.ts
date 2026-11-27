import * as path from 'path';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as yaml from './yaml-loader';
import { IdpPortal } from './idp-portal';

export interface PlatformBootstrapProps {
  readonly cluster: eks.Cluster;
}

/**
 * Installs the IDP platform baseline onto the EKS cluster — the AWS counterpart
 * of what start.sh + setup_gitops.sh do locally on kind:
 *
 *   1. Crossplane (Helm)
 *   2. provider-kubernetes + function-patch-and-transform (Crossplane packages)
 *   3. RBAC + ProviderConfig (in-cluster InjectedIdentity, like the local demo)
 *   4. Argo CD (Helm, self-hosted) — the GitOps engine the Composition targets
 *   5. The downstream-system namespaces (security / SRE / reporting)
 *   6. The Service XRD + Composition (the developer-facing platform API)
 *   7. Crossview (Crossplane resource browser)
 *   8. A default gp3 StorageClass using the Auto Mode EBS provisioner
 *
 * The XRD and Composition are read verbatim from the local-demo packages/ dir
 * so the platform API is identical to the one shown locally — only the cluster
 * underneath changes (kind -> EKS), which is exactly the talk's point.
 *
 * On top of this baseline, IdpPortal installs the developer-facing portal
 * (Gitea + Backstage + Dex) so the full "Onboard a new service" golden path
 * runs end to end on AWS, matching the local demo.
 */
export class PlatformBootstrap extends Construct {
  constructor(scope: Construct, id: string, props: PlatformBootstrapProps) {
    super(scope, id);

    const { cluster } = props;

    // Path to the local-demo packages that hold the platform API manifests.
    // This CDK app lives alongside local-demo under the same talk folder.
    const packagesDir = path.resolve(
      __dirname,
      '..',
      '..',
      'local-demo',
      'packages',
    );

    // ── 1. Crossplane via Helm ────────────────────────────────────────────
    const crossplane = cluster.addHelmChart('Crossplane', {
      chart: 'crossplane',
      repository: 'https://charts.crossplane.io/stable',
      namespace: 'crossplane-system',
      createNamespace: true,
      release: 'crossplane',
      version: '2.4.0',
      values: {
        args: ['--enable-usages'],
      },
      wait: true,
      timeout: cdk.Duration.minutes(10),
    });

    // ── 2. Crossplane provider + function packages ────────────────────────
    const providers = cluster.addManifest(
      'CrossplaneProvider',
      yaml.loadManifest(path.join(packagesDir, '1-crossplane', 'providers.yaml')),
    );
    const functions = cluster.addManifest(
      'CrossplaneFunction',
      yaml.loadManifest(path.join(packagesDir, '1-crossplane', 'functions.yaml')),
    );
    providers.node.addDependency(crossplane);
    functions.node.addDependency(crossplane);

    // ── 3. RBAC + ProviderConfig ──────────────────────────────────────────
    // provider-kubernetes runs with a generated ServiceAccount in
    // crossplane-system. Like the local demo it uses InjectedIdentity, so we
    // bind a broad ClusterRole to every SA in crossplane-system via a group
    // subject — this covers the provider's SA regardless of its generated name.
    const rbac = cluster.addManifest('CrossplaneProviderRbac', {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: { name: 'crossplane-provider-kubernetes-admin' },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'cluster-admin',
      },
      subjects: [
        {
          kind: 'Group',
          name: 'system:serviceaccounts:crossplane-system',
          apiGroup: 'rbac.authorization.k8s.io',
        },
      ],
    });
    rbac.node.addDependency(crossplane);

    const providerConfig = cluster.addManifest(
      'CrossplaneProviderConfig',
      yaml.loadManifest(
        path.join(packagesDir, '1-crossplane', 'providerconfig.yaml'),
      ),
    );
    providerConfig.node.addDependency(providers);
    providerConfig.node.addDependency(rbac);

    // ── 4. Argo CD via Helm (self-hosted) ─────────────────────────────────
    // The Composition creates in-cluster Argo CD Application objects, so a
    // self-hosted Argo CD (with its Application CRD + argocd namespace) is what
    // the golden path targets. Served insecure HTTP, matching the local demo's
    // --insecure patch; reached via `kubectl port-forward` like the other UIs.
    //
    // NOTE: AWS also offers a fully managed "EKS Capability for Argo CD". We do
    // NOT use it here — it runs Argo CD's control plane off-cluster, requires
    // IAM Identity Center, and doesn't match the demo's in-cluster Application
    // model. See lib/argocd-capability-option.ts for a ready-to-flip example.
    const argocd = cluster.addHelmChart('ArgoCD', {
      chart: 'argo-cd',
      repository: 'https://argoproj.github.io/argo-helm',
      namespace: 'argocd',
      createNamespace: true,
      release: 'argocd',
      version: '7.7.0',
      values: {
        configs: {
          params: { 'server.insecure': true },
          cm: {
            // Track resources by annotation, not by the argocd.argoproj.io/instance
            // label. Crossplane copies the Service claim's labels onto the composite
            // (XService) it creates. With label tracking Argo CD then treats the XService
            // as part of the per-service app, finds it is not in Git, prunes it, Crossplane
            // recreates it, and the app never becomes Healthy. Argo CD 3 defaults to
            // annotation tracking (what idpbuilder installs locally); the 7.7.0 chart
            // (Argo CD 2.13) defaults to labels.
            'application.resourceTrackingMethod': 'annotation',
          },
        },
        // ClusterIP — the operator reaches the UI via port-forward (ui model),
        // so no ELB is provisioned.
        server: {
          service: { type: 'ClusterIP' },
        },
      },
      wait: false,
      timeout: cdk.Duration.minutes(10),
    });

    // ── 5. Downstream-system namespaces ───────────────────────────────────
    const namespaces = ['security-system', 'sre-system', 'platform-reporting'];
    const nsManifests = namespaces.map((ns) =>
      cluster.addManifest(`Namespace-${ns}`, {
        apiVersion: 'v1',
        kind: 'Namespace',
        metadata: {
          name: ns,
          labels: { 'lockhead.cloud/platform-system': 'true' },
        },
      }),
    );

    // ── 6. The Service API (XRD + Composition) ────────────────────────────
    const xrd = cluster.addManifest(
      'ServiceXrd',
      yaml.loadManifest(
        path.join(packagesDir, '2-platform-api', 'xrds', 'service-xrd.yaml'),
      ),
    );
    const composition = cluster.addManifest(
      'ServiceComposition',
      yaml.loadManifest(
        path.join(
          packagesDir,
          '2-platform-api',
          'compositions',
          'service-onboarding.yaml',
        ),
      ),
    );

    // The XRD/Composition depend on Crossplane CRDs + the function being present.
    xrd.node.addDependency(crossplane);
    composition.node.addDependency(functions);
    composition.node.addDependency(providerConfig);
    // Composition targets Argo CD Applications + the downstream namespaces.
    composition.node.addDependency(argocd);
    for (const ns of nsManifests) {
      composition.node.addDependency(ns);
    }

    // ── 7. Crossview (Crossplane resource browser) ────────────────────────
    // The same resource browser the local demo installs — lets you see the
    // XRs/claims/composed resources the golden path produces. auth.mode=none:
    // no login, fine for a demo; reached via port-forward.
    const crossview = cluster.addHelmChart('Crossview', {
      chart: 'crossview',
      repository: 'https://crossplane-contrib.github.io/crossview',
      namespace: 'crossview-system',
      createNamespace: true,
      release: 'crossview',
      values: {
        config: { server: { auth: { mode: 'none' } } },
        secrets: {
          dbPassword: 'crossview-demo',
          // Static session secret for the demo. Fine here; for anything real
          // this should come from Secrets Manager.
          sessionSecret: 'crossview-demo-session-secret-change-me',
        },
      },
      wait: false,
      timeout: cdk.Duration.minutes(10),
    });
    crossview.node.addDependency(crossplane);

    // ── Default StorageClass (gp3, Auto Mode provisioner) ─────────────────
    // EKS Auto Mode manages the EBS CSI driver but does NOT create a
    // StorageClass. Gitea and Backstage's Postgres need dynamically
    // provisioned PVCs, so create a gp3 class (marked cluster-default) using
    // the Auto Mode provisioner `ebs.csi.eks.amazonaws.com` — NOT the standard
    // `ebs.csi.aws.com`, which Auto Mode does not run.
    const storageClass = cluster.addManifest('Gp3StorageClass', {
      apiVersion: 'storage.k8s.io/v1',
      kind: 'StorageClass',
      metadata: {
        name: 'gp3',
        annotations: { 'storageclass.kubernetes.io/is-default-class': 'true' },
      },
      provisioner: 'ebs.csi.eks.amazonaws.com',
      volumeBindingMode: 'WaitForFirstConsumer',
      allowVolumeExpansion: true,
      parameters: { type: 'gp3', encrypted: 'true' },
    });

    // ── Developer portal: Gitea + Backstage + Dex ─────────────────────────
    // Installs the portal and seeds the platform-api Gitea repo, then wires the
    // two platform ArgoCD apps + Backstage so the golden path runs end to end.
    new IdpPortal(this, 'IdpPortal', {
      cluster,
      packagesDir,
      // Portal pieces depend on the Service API + Argo CD existing first.
      // Also wait for the StorageClass so Gitea/Postgres PVCs can bind.
      dependsOn: [argocd, xrd, composition, providerConfig, storageClass],
    });
  }
}
