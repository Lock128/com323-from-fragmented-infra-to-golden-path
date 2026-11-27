#!/usr/bin/env node
import 'source-map-support/register';
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { ManagedVpcStack } from '../lib/managed-vpc-stack';
import { ManagedEksStack } from '../lib/managed-eks-stack';
import { GitProvider } from '../lib/git-source';

const app = new cdk.App();

// All tunables live in cdk.json under "managedIdp". Your own values (the
// Identity Center instance and admin) go into the gitignored cdk.local.json
// (see cdk.local.example.json); its "managedIdp" keys win over cdk.json.
// Override on the CLI with e.g. `--context managedIdp:gitProvider=external`.
const base = { ...(app.node.tryGetContext('managedIdp') ?? {}), ...readLocalConfig() };

function readLocalConfig(): Record<string, any> {
  const file = path.join(__dirname, '..', 'cdk.local.json');
  if (!fs.existsSync(file)) return {};
  return JSON.parse(fs.readFileSync(file, 'utf8')).managedIdp ?? {};
}
// A flat `-c managedIdp:<key>=<value>` on the CLI wins over the cdk.json object.
const cfg: Record<string, any> = new Proxy(base, {
  get: (t, k: string) => app.node.tryGetContext(`managedIdp:${k}`) ?? t[k],
});
const clusterName: string = cfg.clusterName ?? 'lockheadcloud-managed';
const kubernetesVersion: string = cfg.kubernetesVersion ?? '1.36';
const gitProvider: GitProvider = cfg.gitProvider ?? 'codecommit';
if (gitProvider !== 'codecommit' && gitProvider !== 'external') {
  throw new Error(`managedIdp.gitProvider must be "codecommit" or "external", got "${gitProvider}"`);
}

const adminPrincipalArn: string | undefined = app.node.tryGetContext('adminPrincipalArn');

// Region is explicit (cdk.json managedIdp.region) rather than taken from the
// active AWS profile, so a profile switch cannot move the deployment.
const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: cfg.region ?? process.env.CDK_DEFAULT_REGION ?? 'us-west-2',
};

const vpcStack = new ManagedVpcStack(app, 'ManagedIdpVpcStack', {
  env,
  description: 'VPC for the managed (EKS Capabilities) IDP demo',
  clusterName,
  maxAzs: Number(cfg.vpcMaxAzs ?? 3),
  natGateways: Number(cfg.vpcNatGateways ?? 1),
});

const eksStack = new ManagedEksStack(app, 'ManagedIdpEksStack', {
  env,
  description:
    'EKS Auto Mode cluster with managed Argo CD, kro and ACK capabilities for the IDP demo',
  vpc: vpcStack.vpc,
  clusterName,
  kubernetesVersion,
  adminPrincipalArn,
  git: {
    provider: gitProvider,
    repositoryName: cfg.repositoryName ?? 'lockheadcloud-managed-platform',
    externalRepoUrl: cfg.externalRepoUrl || undefined,
    serviceRepoPrefix: cfg.serviceRepoPrefix ?? 'svc-',
  },
  portal: String(cfg.portal ?? 'true') !== 'false',
  idc: {
    instanceArn: cfg.idcInstanceArn ?? '',
    region: cfg.idcRegion ?? '',
    adminGroupId: cfg.idcAdminGroupId || undefined,
    adminUserId: cfg.idcAdminUserId || undefined,
  },
});
eksStack.addStackDependency(vpcStack);

app.synth();
