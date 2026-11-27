import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export interface IdpVpcStackProps extends cdk.StackProps {
  /** Logical cluster name — used to tag subnets for EKS/ELB discovery. */
  readonly clusterName: string;
  /** Max number of AZs the VPC spans. Three gives a resilient control plane. */
  readonly maxAzs: number;
  /**
   * Number of NAT gateways. 1 keeps the demo cheap (single AZ egress);
   * bump to maxAzs for production-grade HA.
   */
  readonly natGateways: number;
}

/**
 * The network foundation for the IDP-on-EKS demo.
 *
 * A standard 3-tier-ish VPC: public subnets (for the internet-facing load
 * balancers Argo CD / Backstage / Gitea sit behind) and private subnets with
 * egress (where the EKS worker nodes and all platform workloads run).
 *
 * Subnets are tagged with the Kubernetes ELB discovery tags so the AWS Load
 * Balancer Controller can auto-discover where to place public/internal LBs.
 */
export class IdpVpcStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;

  private readonly azCount: number;

  constructor(scope: Construct, id: string, props: IdpVpcStackProps) {
    super(scope, id, props);
    this.azCount = props.maxAzs;

    this.vpc = new ec2.Vpc(this, 'IdpVpc', {
      maxAzs: props.maxAzs,
      natGateways: props.natGateways,
      ipAddresses: ec2.IpAddresses.cidr('10.40.0.0/16'),
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
        {
          name: 'private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 20,
        },
      ],
    });

    // ELB discovery tags. The AWS Load Balancer Controller reads these to decide
    // which subnets to place internet-facing vs internal load balancers in.
    for (const subnet of this.vpc.publicSubnets) {
      cdk.Tags.of(subnet).add('kubernetes.io/role/elb', '1');
      cdk.Tags.of(subnet).add(`kubernetes.io/cluster/${props.clusterName}`, 'shared');
    }
    for (const subnet of this.vpc.privateSubnets) {
      cdk.Tags.of(subnet).add('kubernetes.io/role/internal-elb', '1');
      cdk.Tags.of(subnet).add(`kubernetes.io/cluster/${props.clusterName}`, 'shared');
    }

    new cdk.CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
      description: 'VPC that hosts the IDP-on-EKS cluster',
      exportName: 'IdpVpcId',
    });
  }

  /**
   * Resolve AZs at deploy time with Fn::GetAZs instead of a synth-time lookup.
   * This keeps `cdk synth`/`diff` runnable without AWS credentials (CI synth
   * checks) AND uses the AZ names that actually exist in the target account:
   * AZ letters map to different physical zones per account, and not every
   * account/region has a, b and c, so hardcoding "<region>a" can fail.
   */
  public get availabilityZones(): string[] {
    return Array.from({ length: this.azCount }, (_, i) =>
      cdk.Fn.select(i, cdk.Fn.getAzs(this.region)),
    );
  }
}
