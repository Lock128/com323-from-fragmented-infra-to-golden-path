import * as cdk from 'aws-cdk-lib';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import { CfnCapability } from 'aws-cdk-lib/aws-eks-v2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

/**
 * OPTIONAL / NOT WIRED IN — the managed "EKS Capability for Argo CD".
 *
 * The demo uses SELF-HOSTED Argo CD (see platform-bootstrap.ts) because the
 * service-onboarding Composition creates in-cluster `argoproj.io` Application
 * objects, and the stage story is "watch the platform create an Argo CD
 * Application right here on the cluster". The managed capability runs Argo CD's
 * control plane OFF your cluster and authenticates via IAM Identity Center, so
 * adopting it means:
 *
 *   1. You must have an IAM Identity Center instance (idcInstanceArn).
 *   2. Login is SSO, not the local `admin` + port-forward flow.
 *   3. The Composition must be reworked to register Applications with the
 *      managed Argo CD instead of writing an in-cluster Application CRD.
 *
 * This construct is a ready-to-flip reference for when you want the managed
 * route. To use it: instantiate it from IdpEksStack, pass your IdC instance
 * ARN + admin group id, and drop the self-hosted Argo CD Helm chart from
 * PlatformBootstrap. See:
 *   https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html
 *   https://docs.aws.amazon.com/eks/latest/userguide/argocd.html
 */
export interface ArgoCdCapabilityOptionProps {
  readonly cluster: eks.Cluster;
  /** ARN of your IAM Identity Center instance. */
  readonly idcInstanceArn: string;
  /** Region of the IdC instance (e.g. "eu-central-1"). */
  readonly idcRegion: string;
  /**
   * IdC group id to grant Argo CD ADMIN. Find it in the IAM Identity Center
   * console (Groups) — this is the group's GUID, not its display name.
   */
  readonly adminGroupId: string;
  /** Optional endpoint prefix for the managed Argo CD server URL. */
  readonly endpointPrefix?: string;
}

export class ArgoCdCapabilityOption extends Construct {
  public readonly capability: CfnCapability;

  constructor(scope: Construct, id: string, props: ArgoCdCapabilityOptionProps) {
    super(scope, id);

    // The capability needs an IAM role it assumes to manage AWS resources on
    // your behalf. Scope this down per the EKS Capability docs for production;
    // the trust policy below lets the EKS service assume it.
    const role = new iam.Role(this, 'ArgoCdCapabilityRole', {
      assumedBy: new iam.ServicePrincipal('eks.amazonaws.com'),
      description: 'Role assumed by the EKS Argo CD capability',
    });

    this.capability = new CfnCapability(this, 'ArgoCd', {
      capabilityName: 'argocd',
      clusterName: props.cluster.clusterName,
      type: 'ARGOCD',
      roleArn: role.roleArn,
      // RETAIN is currently the only supported delete propagation policy.
      deletePropagationPolicy: 'RETAIN',
      configuration: {
        argoCd: {
          namespace: 'argocd',
          endpointPrefix: props.endpointPrefix,
          awsIdc: {
            idcInstanceArn: props.idcInstanceArn,
            idcRegion: props.idcRegion,
          },
          rbacRoleMappings: [
            {
              role: 'ADMIN',
              identities: [{ id: props.adminGroupId, type: 'SSO_GROUP' }],
            },
          ],
        },
      },
    });

    new cdk.CfnOutput(this, 'ArgoCdServerUrl', {
      value: this.capability.attrConfigurationArgoCdServerUrl,
      description: 'Managed Argo CD server URL',
    });
  }
}
