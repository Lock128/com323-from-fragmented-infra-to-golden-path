import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { KubectlV36Layer } from '@aws-cdk/lambda-layer-kubectl-v36';
import { Construct } from 'constructs';
import { GitSource, GitProvider } from './git-source';
import { ManagedCapabilities, IdcConfig } from './managed-capabilities';
import * as path from 'path';
import { ManagedPortal, SCAFFOLD_IMAGE } from './managed-portal';
import { stagePlatformSeed } from './platform-seed';

export interface ManagedEksStackProps extends cdk.StackProps {
  readonly vpc: ec2.IVpc;
  readonly clusterName: string;
  readonly kubernetesVersion: string;
  /** Optional IAM principal granted cluster-admin through an access entry. */
  readonly adminPrincipalArn?: string;
  readonly git: {
    readonly provider: GitProvider;
    readonly repositoryName: string;
    readonly externalRepoUrl?: string;
    /** CodeCommit name prefix for repos the portal creates per service. */
    readonly serviceRepoPrefix: string;
  };
  /** Install Backstage (CodeCommit only). Default true. */
  readonly portal?: boolean;
  readonly idc: IdcConfig;
}

/**
 * EKS Auto Mode cluster that runs the managed capabilities from slide 30:
 *
 *   Argo CD (managed GitOps)  +  kro (compose the Service API)  +  ACK (AWS resources)
 *   on EKS Auto Mode (compute, networking, storage)  +  one Git host (CodeCommit here)
 *
 * Compared with IdpEksStack there is no Crossplane, no self-hosted Argo CD and
 * no Gitea: AWS runs those controllers, and Git lives in CodeCommit (or your
 * own host). The platform definitions in ../platform are synced from Git by
 * Argo CD, so after the first deploy the platform is changed with `git push`.
 */
export class ManagedEksStack extends cdk.Stack {
  public readonly cluster: eks.Cluster;

  constructor(scope: Construct, id: string, props: ManagedEksStackProps) {
    super(scope, id, props);

    if (!props.idc.instanceArn || !(props.idc.adminGroupId || props.idc.adminUserId)) {
      throw new Error(
        'The managed Argo CD capability authenticates through IAM Identity Center. ' +
          'Set managedIdp.idcInstanceArn and managedIdp.idcAdminUserId or managedIdp.idcAdminGroupId ' +
          'in cdk.local.json (copy cdk.local.example.json), or pass --context managedIdp:idcInstanceArn=... etc.',
      );
    }
    const idc: IdcConfig = {
      ...props.idc,
      region: props.idc.region || this.region,
    };

    const mastersRole = new iam.Role(this, 'ClusterMastersRole', {
      assumedBy: new iam.AccountRootPrincipal(),
      description: 'Cluster-admin role for the managed IDP demo (kubectl access)',
    });

    this.cluster = new eks.Cluster(this, 'ManagedCluster', {
      clusterName: props.clusterName,
      version: eks.KubernetesVersion.of(props.kubernetesVersion),
      defaultCapacityType: eks.DefaultCapacityType.AUTOMODE,
      vpc: props.vpc,
      vpcSubnets: [{ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }],
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      mastersRole,
      // Only used to register the cluster with Argo CD and create the
      // platform Application; the controllers themselves are managed.
      kubectlProviderOptions: {
        kubectlLayer: new KubectlV36Layer(this, 'KubectlLayer'),
      },
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
      ],
    });

    if (props.adminPrincipalArn) {
      this.cluster.grantAccess('AdminAccess', props.adminPrincipalArn, [
        eks.AccessPolicy.fromAccessPolicyName('AmazonEKSClusterAdminPolicy', {
          accessScopeType: eks.AccessScopeType.CLUSTER,
        }),
      ]);
    }

    // ── Git host ─────────────────────────────────────────────────────────
    // platform/ is seeded into CodeCommit with the placeholders in
    // platform/backstage/template.yaml filled in.
    const seedDirectory =
      props.git.provider === 'codecommit'
        ? stagePlatformSeed(path.resolve(__dirname, '..', 'platform'), {
            REGION: this.region,
            CLUSTER_NAME: props.clusterName,
            SERVICE_REPO_PREFIX: props.git.serviceRepoPrefix,
            SCAFFOLD_IMAGE,
          })
        : '';
    const git = new GitSource(this, 'Git', {
      provider: props.git.provider,
      repositoryName: props.git.repositoryName,
      externalRepoUrl: props.git.externalRepoUrl,
      seedDirectory,
    });

    // ── Managed capabilities ─────────────────────────────────────────────
    // Argo CD reads CodeCommit directly with its capability role: GitPull only,
    // on the platform repo and on the per-service repos the portal creates.
    const portalEnabled = (props.portal ?? true) && git.repository !== undefined;
    const capabilities = new ManagedCapabilities(this, 'Capabilities', {
      cluster: this.cluster,
      idc,
      argoCdPolicyStatements: git.repository
        ? [
            new iam.PolicyStatement({
              actions: ['codecommit:GitPull'],
              resources: [
                git.repository.repositoryArn,
                ...(portalEnabled
                  ? [this.formatArn({ service: 'codecommit', resource: `${props.git.serviceRepoPrefix}*` })]
                  : []),
              ],
            }),
          ]
        : [],
    });

    // ── Wire Argo CD to the cluster and to Git ───────────────────────────
    // The managed Argo CD does not register the local cluster itself and does
    // not support kubernetes.default.svc, so register it by its ARN under the
    // familiar name "in-cluster".
    const clusterSecret = this.cluster.addManifest('ArgoCdLocalCluster', {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'in-cluster',
        namespace: 'argocd',
        labels: { 'argocd.argoproj.io/secret-type': 'cluster' },
      },
      stringData: {
        name: 'in-cluster',
        server: this.cluster.clusterArn,
        project: 'default',
      },
    });
    clusterSecret.node.addDependency(capabilities.ready);

    // One Application syncs the repo: the downstream CRDs + namespaces
    // (sync-wave 0) and the kro Service RGD (sync-wave 1). backstage/ holds the
    // Backstage template, which is read by Backstage, not applied to the cluster.
    const platformApp = this.cluster.addManifest('PlatformApplication', {
      apiVersion: 'argoproj.io/v1alpha1',
      kind: 'Application',
      metadata: { name: 'platform-api', namespace: 'argocd' },
      spec: {
        project: 'default',
        source: {
          repoURL: git.repoUrl,
          targetRevision: 'main',
          path: '.',
          directory: { recurse: true, exclude: 'backstage/*' },
        },
        destination: { name: 'in-cluster' },
        syncPolicy: {
          automated: { prune: true, selfHeal: true },
          syncOptions: ['ServerSideApply=true'],
        },
      },
    });
    platformApp.node.addDependency(clusterSecret);

    // ── Developer portal (Backstage) ─────────────────────────────────────
    // Only with CodeCommit: the template creates service repos there.
    if (portalEnabled) {
      new ManagedPortal(this, 'Portal', {
        cluster: this.cluster,
        serviceRepoPrefix: props.git.serviceRepoPrefix,
        platformRepo: git.repository!,
        dependsOn: [platformApp],
      });
    }

    // Serialize kubectl-provider operations (see IdpEksStack for the reason:
    // each custom resource holds Lambda concurrency).
    const k8sResources = this.cluster.node
      .findAll()
      .filter((c): c is eks.KubernetesManifest => c instanceof eks.KubernetesManifest);
    for (let i = 1; i < k8sResources.length; i++) {
      k8sResources[i].node.addDependency(k8sResources[i - 1]);
    }

    new cdk.CfnOutput(this, 'ClusterNameOutput', {
      value: this.cluster.clusterName,
      description: 'EKS cluster name',
      exportName: 'ManagedIdpClusterName',
    });
    new cdk.CfnOutput(this, 'UpdateKubeconfigCommand', {
      value: `aws eks update-kubeconfig --name ${this.cluster.clusterName} --region ${this.region} --role-arn ${mastersRole.roleArn}`,
      description: 'Run this to point kubectl at the cluster',
    });
    new cdk.CfnOutput(this, 'ArgoCdServerUrl', {
      value: capabilities.argoCd.attrConfigurationArgoCdServerUrl,
      description: 'Managed Argo CD URL (sign in with IAM Identity Center)',
    });
    new cdk.CfnOutput(this, 'PlatformRepoUrl', {
      value: git.repoUrl,
      description: 'Git repository Argo CD syncs the platform definitions from',
    });
  }
}
