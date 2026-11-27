import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { KubectlV36Layer } from '@aws-cdk/lambda-layer-kubectl-v36';
import { Construct } from 'constructs';
import { PlatformBootstrap } from './platform-bootstrap';

export interface IdpEksStackProps extends cdk.StackProps {
  readonly vpc: ec2.IVpc;
  readonly clusterName: string;
  readonly kubernetesVersion: string;
  /**
   * Optional IAM principal (role/user ARN) granted cluster-admin via an EKS
   * access entry, so you can run kubectl locally after deploy.
   */
  readonly adminPrincipalArn?: string;
}

/**
 * Provisions the managed EKS cluster that hosts the service-onboarding golden
 * path on AWS — the cloud counterpart of the local kind/idpbuilder demo.
 *
 * Built on the aws-eks-v2 L2 constructs with **EKS Auto Mode** enabled
 * (see https://aws.amazon.com/blogs/devops/announcing-the-new-aws-cdk-eks-v2-l2-constructs/).
 * Auto Mode means AWS manages compute (Karpenter), storage (EBS CSI), and the
 * AWS Load Balancer Controller as built-in components — so there is no node
 * group, no add-ons, and no EBS CSI IRSA role to define here. We just declare
 * the cluster and the workloads; EKS provisions capacity on demand.
 *
 * What this creates:
 *   - An EKS Auto Mode cluster (public + private endpoint) in the demo VPC
 *   - A kubectl provider (so addManifest/addHelmChart work)
 *   - An OIDC provider for IRSA
 *   - A cluster-admin access entry for the operator (local kubectl)
 *   - The platform baseline + portal (Crossplane, Service API, Gitea,
 *     Backstage, Argo CD, Crossview) — see PlatformBootstrap.
 */
export class IdpEksStack extends cdk.Stack {
  public readonly cluster: eks.Cluster;

  constructor(scope: Construct, id: string, props: IdpEksStackProps) {
    super(scope, id, props);

    // Map the "1.36" context string onto the CDK KubernetesVersion enum. We pin
    // to a version that matches the bundled kubectl layer (v36).
    const version = eks.KubernetesVersion.of(props.kubernetesVersion);

    // The role the CLI/CI principal uses to administer the cluster. Granted
    // cluster-admin via an access entry (the only auth path in eks-v2, which
    // uses API authentication mode — aws-auth ConfigMap is gone).
    const mastersRole = new iam.Role(this, 'ClusterMastersRole', {
      assumedBy: new iam.AccountRootPrincipal(),
      description: 'Cluster-admin role for the IDP-on-EKS demo (kubectl access)',
    });

    this.cluster = new eks.Cluster(this, 'IdpCluster', {
      clusterName: props.clusterName,
      version,
      // Auto Mode is the default in eks-v2, but we set it explicitly so the
      // intent is obvious. AWS manages compute/storage/networking components.
      defaultCapacityType: eks.DefaultCapacityType.AUTOMODE,
      vpc: props.vpc,
      vpcSubnets: [{ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }],
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      mastersRole,
      // Required for addManifest/addHelmChart — eks-v2 only creates the kubectl
      // handler when kubectlProviderOptions is provided.
      kubectlProviderOptions: {
        kubectlLayer: new KubectlV36Layer(this, 'KubectlLayer'),
      },
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
      ],
    });

    // Grant the named principal (e.g. your SSO role) cluster-admin so
    // `aws eks update-kubeconfig` + kubectl works from your laptop/CI directly.
    if (props.adminPrincipalArn) {
      this.cluster.grantAccess('AdminAccess', props.adminPrincipalArn, [
        eks.AccessPolicy.fromAccessPolicyName('AmazonEKSClusterAdminPolicy', {
          accessScopeType: eks.AccessScopeType.CLUSTER,
        }),
      ]);
    }

    // Install the IDP platform baseline + portal onto the cluster: Crossplane +
    // the Service API, Gitea, Backstage/Dex, Argo CD, and Crossview — so the
    // "Onboard a new service" golden path runs end to end on AWS.
    new PlatformBootstrap(this, 'PlatformBootstrap', {
      cluster: this.cluster,
    });

    // Run the kubectl-provider operations strictly one after another.
    //
    // Every Helm chart / manifest is a CloudFormation custom resource backed by
    // the same Lambda, and each in-flight one holds ~2 concurrent executions
    // (framework function + kubectl handler). CloudFormation otherwise starts
    // all ~35 at once, which exceeds the default account limit (10 for new
    // accounts) and fails with "TooManyRequestsException: Rate Exceeded".
    // Chaining them in creation order keeps usage at ~2 executions. All existing
    // dependencies point at earlier-created resources, so this adds no cycles.
    const k8sResources = this.cluster.node
      .findAll()
      .filter(
        (c): c is eks.KubernetesManifest | eks.HelmChart =>
          c instanceof eks.KubernetesManifest || c instanceof eks.HelmChart,
      );
    for (let i = 1; i < k8sResources.length; i++) {
      k8sResources[i].node.addDependency(k8sResources[i - 1]);
    }

    new cdk.CfnOutput(this, 'ClusterNameOutput', {
      value: this.cluster.clusterName,
      description: 'EKS cluster name',
      exportName: 'IdpClusterName',
    });
    new cdk.CfnOutput(this, 'UpdateKubeconfigCommand', {
      value: `aws eks update-kubeconfig --name ${this.cluster.clusterName} --region ${this.region} --role-arn ${mastersRole.roleArn}`,
      description: 'Run this to point kubectl at the cluster',
    });
    new cdk.CfnOutput(this, 'OidcProviderArn', {
      value: this.cluster.openIdConnectProvider.openIdConnectProviderArn,
      description: 'OIDC provider ARN used for IRSA',
    });
  }
}
