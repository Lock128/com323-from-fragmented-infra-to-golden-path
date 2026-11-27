import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export interface ManagedVpcStackProps extends cdk.StackProps {
  /** Cluster name, used for the Kubernetes subnet discovery tags. */
  readonly clusterName: string;
  readonly maxAzs: number;
  /** 1 keeps the demo cheap; use maxAzs for per-AZ egress. */
  readonly natGateways: number;
}

/**
 * VPC for the fully managed (EKS Capabilities) variant of the IDP demo.
 * Public + private-with-egress subnets, tagged for load balancer discovery.
 * Uses 10.41.0.0/16 so it can be peered with the self-hosted variant's VPC
 * (10.40.0.0/16) if both run in the same account.
 */
export class ManagedVpcStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;

  constructor(scope: Construct, id: string, props: ManagedVpcStackProps) {
    super(scope, id, props);

    this.vpc = new ec2.Vpc(this, 'ManagedVpc', {
      maxAzs: props.maxAzs,
      natGateways: props.natGateways,
      ipAddresses: ec2.IpAddresses.cidr('10.41.0.0/16'),
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 20 },
      ],
    });

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
      description: 'VPC that hosts the managed IDP cluster',
      exportName: 'ManagedIdpVpcId',
    });
  }
}
