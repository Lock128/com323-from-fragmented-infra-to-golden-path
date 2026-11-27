import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { IdpVpcStack } from '../lib/idp-vpc-stack';
import { IdpEksStack } from '../lib/idp-eks-stack';

const env = { account: '123456789012', region: 'eu-central-1' };

function synth() {
  const app = new cdk.App();
  const vpcStack = new IdpVpcStack(app, 'IdpVpcStack', {
    env,
    clusterName: 'test-idp',
    maxAzs: 2,
    natGateways: 1,
  });
  const eksStack = new IdpEksStack(app, 'IdpEksStack', {
    env,
    vpc: vpcStack.vpc,
    clusterName: 'test-idp',
    kubernetesVersion: '1.36',
  });
  return {
    vpc: Template.fromStack(vpcStack),
    eks: Template.fromStack(eksStack),
  };
}

describe('IDP-on-EKS infrastructure', () => {
  const templates = synth();

  test('VPC stack creates a VPC with public + private subnets', () => {
    templates.vpc.resourceCountIs('AWS::EC2::VPC', 1);
    // 2 AZs x (1 public + 1 private) = 4 subnets
    templates.vpc.resourceCountIs('AWS::EC2::Subnet', 4);
    templates.vpc.resourceCountIs('AWS::EC2::NatGateway', 1);
  });

  test('EKS cluster uses Auto Mode (no managed node group)', () => {
    // Auto Mode: compute is managed by EKS, so there is no Nodegroup resource.
    templates.eks.resourceCountIs('AWS::EKS::Nodegroup', 0);
    templates.eks.hasResourceProperties('AWS::EKS::Cluster', {
      ComputeConfig: { Enabled: true },
      StorageConfig: { BlockStorage: { Enabled: true } },
      KubernetesNetworkConfig: { ElasticLoadBalancing: { Enabled: true } },
    });
  });

  test('EKS cluster enables control-plane logging', () => {
    templates.eks.hasResourceProperties('AWS::EKS::Cluster', {
      Logging: {
        ClusterLogging: {
          EnabledTypes: [
            { Type: 'api' },
            { Type: 'audit' },
            { Type: 'authenticator' },
          ],
        },
      },
    });
  });

  test('kubectl-provider resources are serialized (Lambda concurrency safe)', () => {
    const resources = Object.values(templates.eks.toJSON().Resources as Record<string, any>)
      .filter((r) => String(r.Type).startsWith('Custom::AWSCDK-EKS-'))
      .filter((r) => r.Type !== 'Custom::AWSCDK-EKS-Cluster');
    expect(resources.length).toBeGreaterThan(10);
    // Every resource except the first must wait for another one.
    const withoutDeps = resources.filter((r) => !r.DependsOn || r.DependsOn.length === 0);
    expect(withoutDeps.length).toBeLessThanOrEqual(1);
    // And far fewer than the 37 that exceeded the account limit before.
    expect(resources.length).toBeLessThan(25);
  });

  test('platform bootstrap installs the Helm charts for the IDP stack', () => {
    const charts = templates.eks.findResources(
      'Custom::AWSCDK-EKS-HelmChart',
    );
    const chartNames = Object.values(charts).map((r: any) => r.Properties.Chart);
    expect(chartNames).toEqual(
      expect.arrayContaining([
        'crossplane',
        'argo-cd',
        'gitea',
        'crossview',
      ]),
    );
  });
});
