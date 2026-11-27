#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { IdpVpcStack } from '../lib/idp-vpc-stack';
import { IdpEksStack } from '../lib/idp-eks-stack';

const app = new cdk.App();

// All tunables live in cdk.json under the "idp" context key; override any of
// them on the CLI with e.g. `--context idp:nodeDesiredSize=4` or by editing
// cdk.json. Defaults produce a small, demo-sized cluster.
const idp = app.node.tryGetContext('idp') ?? {};

const clusterName: string = idp.clusterName ?? 'lockheadcloud-idp';
const kubernetesVersion: string = idp.kubernetesVersion ?? '1.36';
const vpcMaxAzs: number = Number(idp.vpcMaxAzs ?? 3);
const vpcNatGateways: number = Number(idp.vpcNatGateways ?? 1);
// Note: with EKS Auto Mode there is no node group to size — EKS provisions and
// scales compute automatically, so the old node* tunables are gone.

// Optional: an IAM principal ARN to grant kubectl cluster-admin, so you can
// drive the cluster from your laptop/CI after deploy. Pass via:
//   --context adminPrincipalArn=arn:aws:iam::<acct>:role/<role>
const adminPrincipalArn: string | undefined =
  app.node.tryGetContext('adminPrincipalArn');

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-west-2',
};

const vpcStack = new IdpVpcStack(app, 'IdpVpcStack', {
  env,
  description:
    'VPC for the re:Invent 2026 IDP-on-EKS demo (public + private subnets, ELB discovery tags)',
  clusterName,
  maxAzs: vpcMaxAzs,
  natGateways: vpcNatGateways,
});

const eksStack = new IdpEksStack(app, 'IdpEksStack', {
  env,
  description:
    'EKS Auto Mode cluster + Crossplane + Service API + portal for the IDP-on-EKS golden-path demo',
  vpc: vpcStack.vpc,
  clusterName,
  kubernetesVersion,
  adminPrincipalArn,
});

eksStack.addStackDependency(vpcStack);

app.synth();
