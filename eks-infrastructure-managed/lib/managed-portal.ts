import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as codecommit from 'aws-cdk-lib/aws-codecommit';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct, IDependable } from 'constructs';
import {
  backstageManifests,
  BACKSTAGE_NAMESPACE,
  BACKSTAGE_SERVICE_ACCOUNT,
  SCAFFOLDER_SERVICE_ACCOUNT,
} from './backstage';
import { loadSkeleton } from './service-skeleton';

export interface ManagedPortalProps {
  readonly cluster: eks.Cluster;
  /** CodeCommit repo name prefix for onboarded services (e.g. "svc-"). */
  readonly serviceRepoPrefix: string;
  /** Platform repo; Backstage reads the golden-path template from it. */
  readonly platformRepo: codecommit.IRepository;
  /** Must exist first: the argocd namespace + cluster registration. */
  readonly dependsOn: IDependable[];
}

/** Pinned aws-cli image used by the scaffold Job (needs sh, sed, base64). */
export const SCAFFOLD_IMAGE = 'public.ecr.aws/aws-cli/aws-cli:2.40.4';

/**
 * Backstage portal on top of the managed capabilities: Backstage + Dex +
 * Postgres, the catalog wiring to the golden-path template in the platform
 * repo, and the CodeCommit scaffold Job's
 * IAM role (EKS Pod Identity, scoped to repos named <prefix>*).
 */
export class ManagedPortal extends Construct {
  constructor(scope: Construct, id: string, props: ManagedPortalProps) {
    super(scope, id);
    const { cluster } = props;
    const stack = cdk.Stack.of(this);
    const region = stack.region;

    // ── IAM for the scaffold Job ─────────────────────────────────────────
    const scaffolderRole = new iam.Role(this, 'ScaffolderRole', {
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com').withSessionTags(),
      description: 'Backstage scaffold Job: creates and seeds service repos in CodeCommit',
    });
    scaffolderRole.addToPolicy(
      new iam.PolicyStatement({
        actions: [
          'codecommit:CreateRepository',
          'codecommit:GetRepository',
          'codecommit:GetBranch',
          'codecommit:CreateCommit',
          'codecommit:TagResource',
        ],
        resources: [
          stack.formatArn({ service: 'codecommit', resource: `${props.serviceRepoPrefix}*` }),
        ],
      }),
    );
    // EKS Auto Mode ships the Pod Identity agent, so no add-on is needed.
    new eks.CfnPodIdentityAssociation(this, 'ScaffolderPodIdentity', {
      clusterName: cluster.clusterName,
      namespace: BACKSTAGE_NAMESPACE,
      serviceAccount: SCAFFOLDER_SERVICE_ACCOUNT,
      roleArn: scaffolderRole.roleArn,
    });

    // ── Default StorageClass for the Postgres PVC ────────────────────────
    // Auto Mode runs the EBS CSI driver as ebs.csi.eks.amazonaws.com but
    // creates no StorageClass.
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

    // ── Backstage identity (IRSA) ────────────────────────────────────────
    // Backstage reads catalog files from CodeCommit with the AWS SDK default
    // chain. The SDK in the pinned CNOE image (credential-providers 3.502)
    // predates Pod Identity support, but handles IRSA web identity tokens.
    const namespace = cluster.addManifest('BackstageNamespace', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: BACKSTAGE_NAMESPACE },
    });
    const backstageSa = cluster.addServiceAccount('BackstageServiceAccount', {
      name: BACKSTAGE_SERVICE_ACCOUNT,
      namespace: BACKSTAGE_NAMESPACE,
      identityType: eks.IdentityType.IRSA,
    });
    backstageSa.node.addDependency(namespace);
    backstageSa.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['codecommit:GetFile', 'codecommit:GetFolder'],
        resources: [
          props.platformRepo.repositoryArn,
          stack.formatArn({ service: 'codecommit', resource: `${props.serviceRepoPrefix}*` }),
        ],
      }),
    );

    // ── Backstage ────────────────────────────────────────────────────────
    const skeleton = loadSkeleton({
      skeletonDir: path.resolve(
        __dirname, '..', '..', 'local-demo', 'packages', '5-backstage', 'service-template', 'skeleton',
      ),
      repoUrlPrefix: `https://git-codecommit.${region}.amazonaws.com/v1/repos/${props.serviceRepoPrefix}`,
    });
    const manifests = backstageManifests({
      postgresPassword: 'backstage-demo',
      region,
      platformRepoName: props.platformRepo.repositoryName,
      skeleton,
      scaffoldScript: fs.readFileSync(path.resolve(__dirname, '..', 'portal', 'scaffold.sh'), 'utf8'),
    });
    const backstage = cluster.addManifest('Backstage', ...manifests);
    backstage.node.addDependency(storageClass, backstageSa, ...props.dependsOn);
  }
}
