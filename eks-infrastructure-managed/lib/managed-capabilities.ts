import * as cdk from 'aws-cdk-lib';
import * as eks from 'aws-cdk-lib/aws-eks-v2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct, IDependable } from 'constructs';

export interface IdcConfig {
  /** ARN of the IAM Identity Center instance Argo CD authenticates against. */
  readonly instanceArn: string;
  /** Region of the Identity Center instance. */
  readonly region: string;
  /** Identity Center group ID (GUID) that gets Argo CD ADMIN. */
  readonly adminGroupId?: string;
  /** Identity Center user ID (GUID) that gets Argo CD ADMIN. */
  readonly adminUserId?: string;
}

export interface ManagedCapabilitiesProps {
  readonly cluster: eks.Cluster;
  readonly idc: IdcConfig;
  /** Extra statements for the Argo CD capability role (e.g. codecommit:GitPull). */
  readonly argoCdPolicyStatements?: iam.PolicyStatement[];
}

const CLUSTER_ADMIN_POLICY = 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy';

/**
 * The three EKS Capabilities behind slide 30: managed Argo CD, kro and ACK.
 * AWS runs the controllers outside the cluster, so nothing is installed in it
 * except the CRDs each capability registers.
 *
 * Each capability assumes an IAM "capability role" (trust principal
 * capabilities.eks.amazonaws.com). EKS creates an access entry for that role
 * automatically, but with no Kubernetes permissions beyond the capability's own
 * CRDs. Because the entry is created by EKS, it cannot be declared with
 * AWS::EKS::AccessEntry (name clash), so the policy association is done with
 * an SDK call after the capability exists.
 *
 * DEMO-GRADE: Argo CD and kro get AmazonEKSClusterAdminPolicy so they can apply
 * arbitrary CRDs/RGDs. Scope this down (custom RBAC) for real use.
 */
export class ManagedCapabilities extends Construct {
  public readonly argoCd: eks.CfnCapability;
  public readonly kro: eks.CfnCapability;
  public readonly ack: eks.CfnCapability;
  public readonly argoCdRole: iam.Role;
  public readonly ackRole: iam.Role;
  /** Resources that must exist before Argo CD Applications / kro RGDs are applied. */
  public readonly ready: IDependable;

  constructor(scope: Construct, id: string, props: ManagedCapabilitiesProps) {
    super(scope, id);
    const { cluster, idc } = props;

    // ── Argo CD ──────────────────────────────────────────────────────────
    this.argoCdRole = this.capabilityRole('ArgoCdRole', 'Argo CD');
    for (const s of props.argoCdPolicyStatements ?? []) {
      this.argoCdRole.addToPolicy(s);
    }
    this.argoCd = new eks.CfnCapability(this, 'ArgoCd', {
      capabilityName: 'argocd',
      clusterName: cluster.clusterName,
      type: 'ARGOCD',
      roleArn: this.argoCdRole.roleArn,
      deletePropagationPolicy: 'RETAIN',
      configuration: {
        argoCd: {
          namespace: 'argocd',
          awsIdc: { idcInstanceArn: idc.instanceArn, idcRegion: idc.region },
          rbacRoleMappings: [
            {
              role: 'ADMIN',
              identities: [
                ...(idc.adminGroupId ? [{ id: idc.adminGroupId, type: 'SSO_GROUP' }] : []),
                ...(idc.adminUserId ? [{ id: idc.adminUserId, type: 'SSO_USER' }] : []),
              ],
            },
          ],
        },
      },
    });

    // ── kro ──────────────────────────────────────────────────────────────
    // kro makes no AWS API calls: the role only carries the trust policy.
    const kroRole = this.capabilityRole('KroRole', 'kro');
    this.kro = new eks.CfnCapability(this, 'Kro', {
      capabilityName: 'kro',
      clusterName: cluster.clusterName,
      type: 'KRO',
      roleArn: kroRole.roleArn,
      deletePropagationPolicy: 'RETAIN',
    });

    // ── ACK ──────────────────────────────────────────────────────────────
    // Simple permission model (single account): AWS permissions sit directly on
    // the capability role, limited to what the Service API creates (ECR repos).
    // For multi-team or multi-account use, switch to IAM Role Selectors.
    this.ackRole = this.capabilityRole('AckRole', 'ACK');
    this.ackRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ManageEcrRepositories',
        actions: [
          'ecr:CreateRepository',
          'ecr:DeleteRepository',
          'ecr:DescribeRepositories',
          'ecr:ListTagsForResource',
          'ecr:TagResource',
          'ecr:UntagResource',
          'ecr:PutImageScanningConfiguration',
          'ecr:PutImageTagMutability',
          'ecr:GetRepositoryPolicy',
          'ecr:SetRepositoryPolicy',
          'ecr:DeleteRepositoryPolicy',
          'ecr:GetLifecyclePolicy',
          'ecr:PutLifecyclePolicy',
          'ecr:DeleteLifecyclePolicy',
        ],
        resources: [
          cdk.Stack.of(this).formatArn({
            service: 'ecr',
            resource: 'repository',
            resourceName: '*',
          }),
        ],
      }),
    );
    this.ack = new eks.CfnCapability(this, 'Ack', {
      capabilityName: 'ack',
      clusterName: cluster.clusterName,
      type: 'ACK',
      roleArn: this.ackRole.roleArn,
      deletePropagationPolicy: 'RETAIN',
    });

    // ── Kubernetes permissions for Argo CD and kro ───────────────────────
    const argoAdmin = this.grantClusterAdmin('ArgoCdAdmin', cluster, this.argoCd, this.argoCdRole);
    const kroAdmin = this.grantClusterAdmin('KroAdmin', cluster, this.kro, kroRole);

    // ACK's own access entry already carries AmazonEKSACKPolicy; no extra grant.
    const ready = new Construct(this, 'Ready');
    ready.node.addDependency(argoAdmin, kroAdmin, this.ack);
    this.ready = ready;
  }

  private capabilityRole(id: string, label: string): iam.Role {
    return new iam.Role(this, id, {
      assumedBy: new iam.ServicePrincipal('capabilities.eks.amazonaws.com').withSessionTags(),
      description: `Amazon EKS ${label} capability role (managed IDP demo)`,
    });
  }

  /** Associates AmazonEKSClusterAdminPolicy with the capability's auto-created access entry. */
  private grantClusterAdmin(
    id: string,
    cluster: eks.Cluster,
    capability: eks.CfnCapability,
    role: iam.Role,
  ): cr.AwsCustomResource {
    const stack = cdk.Stack.of(this);
    const params = {
      clusterName: cluster.clusterName,
      principalArn: role.roleArn,
      policyArn: CLUSTER_ADMIN_POLICY,
    };
    const res = new cr.AwsCustomResource(this, id, {
      onCreate: {
        service: 'EKS',
        action: 'associateAccessPolicy',
        parameters: { ...params, accessScope: { type: 'cluster' } },
        physicalResourceId: cr.PhysicalResourceId.of(`${cluster.clusterName}/${id}`),
      },
      onDelete: {
        service: 'EKS',
        action: 'disassociateAccessPolicy',
        parameters: params,
        // The access entry disappears with the capability; nothing left to undo.
        ignoreErrorCodesMatching: '.*',
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          actions: ['eks:AssociateAccessPolicy', 'eks:DisassociateAccessPolicy'],
          resources: [
            cluster.clusterArn,
            stack.formatArn({
              service: 'eks',
              resource: 'access-entry',
              resourceName: `${cluster.clusterName}/*`,
            }),
          ],
        }),
      ]),
      installLatestAwsSdk: false,
    });
    res.node.addDependency(capability);
    return res;
  }
}
