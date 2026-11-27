import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ManagedVpcStack } from '../lib/managed-vpc-stack';
import { ManagedEksStack } from '../lib/managed-eks-stack';

/**
 * The managed app must share no infrastructure with ../eks-infrastructure
 * (stacks IdpVpcStack/IdpEksStack, cluster lockheadcloud-idp, VPC 10.40.0.0/16,
 * exports IdpVpcId/IdpClusterName, default CDK bootstrap "hnb659fds").
 */
const cdkJson = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', 'cdk.json'), 'utf8'));
const cfg = cdkJson.context.managedIdp;

function synth() {
  // Same context the CLI passes from cdk.json (bootstrap qualifier etc.).
  const app = new cdk.App({ context: cdkJson.context });
  const env = { account: '123456789012', region: cfg.region };
  const vpc = new ManagedVpcStack(app, 'ManagedIdpVpcStack', { env, clusterName: cfg.clusterName, maxAzs: 2, natGateways: 1 });
  const eks = new ManagedEksStack(app, 'ManagedIdpEksStack', {
    env,
    vpc: vpc.vpc,
    clusterName: cfg.clusterName,
    kubernetesVersion: cfg.kubernetesVersion,
    git: { provider: 'codecommit', repositoryName: cfg.repositoryName, serviceRepoPrefix: cfg.serviceRepoPrefix },
    // cdk.json ships with empty Identity Center values; use placeholders here.
    idc: {
      instanceArn: cfg.idcInstanceArn || 'arn:aws:sso:::instance/ssoins-1234567890abcdef',
      region: cfg.idcRegion || 'us-east-1',
      adminUserId: cfg.idcAdminUserId || '11111111-2222-3333-4444-555555555555',
    },
  });
  return [vpc, eks].map((s) => ({ name: s.stackName, t: Template.fromStack(s), json: JSON.stringify(Template.fromStack(s).toJSON()) }));
}

describe('isolation from ../eks-infrastructure', () => {
  const stacks = synth();

  test('own CDK bootstrap: qualifier and toolkit stack', () => {
    expect(cdkJson.toolkitStackName).toBe('CDKToolkit-ManagedIdp');
    const q = cdkJson.context['@aws-cdk/core:bootstrapQualifier'];
    expect(q).toMatch(/^[a-z0-9]{1,10}$/);
    expect(q).not.toBe('hnb659fds');
    for (const { json } of stacks) {
      expect(json).toContain(`/cdk-bootstrap/${q}/version`);
      expect(json).not.toContain('hnb659fds');
    }
  });

  test('names differ from the self-hosted variant', () => {
    expect(stacks.map((s) => s.name)).toEqual(['ManagedIdpVpcStack', 'ManagedIdpEksStack']);
    expect(cfg.clusterName).not.toBe('lockheadcloud-idp');
    const all = stacks.map((s) => s.json).join('');
    expect(all).not.toMatch(/"Name":"Idp(VpcId|ClusterName)"|(?<!Managed)IdpVpcStack:|lockheadcloud-idp|10\.40\./);
  });

  test('no imports from outside this app', () => {
    for (const { json } of stacks) {
      for (const m of json.matchAll(/"Fn::ImportValue":"([^"]+)"/g)) {
        expect(m[1]).toMatch(/^ManagedIdpVpcStack:/);
      }
    }
  });
});
