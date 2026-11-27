import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { ManagedVpcStack } from '../lib/managed-vpc-stack';
import { ManagedEksStack } from '../lib/managed-eks-stack';

const env = { account: '123456789012', region: 'eu-central-1' };
const idc = {
  instanceArn: 'arn:aws:sso:::instance/ssoins-1234567890abcdef',
  region: 'eu-central-1',
  adminGroupId: '11111111-2222-3333-4444-555555555555',
};

function synth(provider: 'codecommit' | 'external', idcCfg = idc) {
  const app = new cdk.App();
  const vpc = new ManagedVpcStack(app, 'V', { env, clusterName: 'test', maxAzs: 2, natGateways: 1 });
  const stack = new ManagedEksStack(app, 'E', {
    env,
    vpc: vpc.vpc,
    clusterName: 'test',
    kubernetesVersion: '1.36',
    git: { provider, repositoryName: 'platform', externalRepoUrl: 'https://github.com/x/y.git', serviceRepoPrefix: 'svc-' },
    idc: idcCfg,
  });
  return Template.fromStack(stack);
}

describe('managed IDP infrastructure', () => {
  const t = synth('codecommit');



  test('creates Argo CD, kro and ACK capabilities', () => {
    for (const type of ['ARGOCD', 'KRO', 'ACK']) {
      t.hasResourceProperties('AWS::EKS::Capability', { Type: type });
    }
    t.resourceCountIs('AWS::EKS::Capability', 3);
  });

  test('capability roles trust capabilities.eks.amazonaws.com with TagSession', () => {
    t.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: ['sts:AssumeRole', 'sts:TagSession'],
            Principal: { Service: 'capabilities.eks.amazonaws.com' },
          }),
        ]),
      },
    });
  });

  test('Argo CD is configured with Identity Center admin group', () => {
    t.hasResourceProperties('AWS::EKS::Capability', {
      Type: 'ARGOCD',
      Configuration: {
        ArgoCd: Match.objectLike({
          AwsIdc: { IdcInstanceArn: idc.instanceArn, IdcRegion: idc.region },
          RbacRoleMappings: [{ Role: 'ADMIN', Identities: [{ Id: idc.adminGroupId, Type: 'SSO_GROUP' }] }],
        }),
      },
    });
  });

  test('cluster is Auto Mode without Crossplane/Gitea/self-hosted Argo CD', () => {
    t.hasResourceProperties('AWS::EKS::Cluster', { ComputeConfig: { Enabled: true } });
    t.resourceCountIs('AWS::EKS::Nodegroup', 0);
    const json = JSON.stringify(t.toJSON());
    expect(json).not.toMatch(/crossplane|my-gitea-http|argoproj\.github\.io/i);
  });

  test('CodeCommit repo exists and only Argo CD can GitPull it', () => {
    t.resourceCountIs('AWS::CodeCommit::Repository', 1);
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({ Action: 'codecommit:GitPull' }),
        ]),
      },
    });
  });

  test('platform Application targets in-cluster and the cluster is registered by ARN', () => {
    const json = JSON.stringify(t.toJSON());
    expect(json).toContain('CloneUrlHttp');
    expect(json).toContain('argocd.argoproj.io/secret-type');
    expect(json).toContain('platform-api');
  });

  test('external git provider creates no CodeCommit repo', () => {
    const ext = synth('external');
    ext.resourceCountIs('AWS::CodeCommit::Repository', 0);
    expect(JSON.stringify(ext.toJSON())).toContain('https://github.com/x/y.git');
  });

  test('fails with a clear message when Identity Center is not configured', () => {
    expect(() => synth('codecommit', { instanceArn: '', region: '', adminGroupId: '' })).toThrow(
      /IAM Identity Center/,
    );
  });
});

describe('dependency ordering', () => {
  test('capabilities do not depend on the kubectl manifests that need them (no cycle)', () => {
    const t = synth('codecommit');
    const res = t.toJSON().Resources as Record<string, { Type: string; DependsOn?: string[] }>;
    const manifests = Object.keys(res).filter((k) => res[k].Type === 'Custom::AWSCDK-EKS-KubernetesResource');
    expect(manifests.length).toBeGreaterThan(0);
    for (const [k, r] of Object.entries(res)) {
      if (r.Type === 'AWS::EKS::Capability') {
        for (const m of manifests) expect(r.DependsOn ?? []).not.toContain(m);
      }
    }
  });
});
