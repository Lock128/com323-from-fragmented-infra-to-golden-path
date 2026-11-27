import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { parse } from 'yaml';
import { ManagedVpcStack } from '../lib/managed-vpc-stack';
import { ManagedEksStack } from '../lib/managed-eks-stack';
import { loadSkeleton } from '../lib/service-skeleton';
import * as fs from 'fs';
import { stagePlatformSeed } from '../lib/platform-seed';
import { SCAFFOLD_IMAGE } from '../lib/managed-portal';

const env = { account: '123456789012', region: 'eu-central-1' };

function synth(opts: { provider?: 'codecommit' | 'external'; portal?: boolean; userOnly?: boolean } = {}) {
  const app = new cdk.App();
  const vpc = new ManagedVpcStack(app, 'V', { env, clusterName: 'test', maxAzs: 2, natGateways: 1 });
  const stack = new ManagedEksStack(app, 'E', {
    env,
    vpc: vpc.vpc,
    clusterName: 'test',
    kubernetesVersion: '1.36',
    portal: opts.portal,
    git: {
      provider: opts.provider ?? 'codecommit',
      repositoryName: 'platform',
      externalRepoUrl: 'https://github.com/x/y.git',
      serviceRepoPrefix: 'svc-',
    },
    idc: {
      instanceArn: 'arn:aws:sso:::instance/ssoins-1',
      region: 'eu-central-1',
      adminUserId: 'user-1',
      adminGroupId: opts.userOnly ? undefined : 'group-1',
    },
  });
  return Template.fromStack(stack);
}

const skeletonDir = path.resolve(
  __dirname, '..', '..', 'local-demo', 'packages', '5-backstage', 'service-template', 'skeleton',
);

describe('portal', () => {
  const t = synth();
  const json = JSON.stringify(t.toJSON());

  test('installs Backstage, the template and the scaffold Job prerequisites', () => {
    expect(json).toContain('ghcr.io/cnoe-io/backstage-app');
    expect(json).toContain('backstage/template.yaml');
    expect(json).toContain('service-skeleton');
    expect(json).toContain('repo-scaffolder');
  });

  test('scaffold Job identity uses Pod Identity, scoped to svc-* repos', () => {
    t.hasResourceProperties('AWS::EKS::PodIdentityAssociation', {
      Namespace: 'backstage',
      ServiceAccount: 'repo-scaffolder',
    });
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: Match.arrayWith(['codecommit:CreateRepository', 'codecommit:CreateCommit']),
            Resource: Match.objectLike({
              'Fn::Join': Match.arrayWith([Match.arrayWith([':codecommit:eu-central-1:123456789012:svc-*'])]),
            }),
          }),
        ]),
      },
    });
  });

  test('Argo CD can pull the per-service repos', () => {
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: 'codecommit:GitPull',
            Resource: Match.arrayWith([
              Match.objectLike({ 'Fn::Join': Match.arrayWith([Match.arrayWith([':codecommit:eu-central-1:123456789012:svc-*'])]) }),
            ]),
          }),
        ]),
      },
    });
  });

  test('Backstage reads CodeCommit through IRSA, scoped to svc-* repos', () => {
    expect(json).toContain('awsCodeCommit');
    expect(json).toContain('eks.amazonaws.com/role-arn');
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: ['codecommit:GetFile', 'codecommit:GetFolder'],
            Resource: Match.arrayWith([
              Match.objectLike({
                'Fn::Join': Match.arrayWith([Match.arrayWith([':codecommit:eu-central-1:123456789012:svc-*'])]),
              }),
            ]),
          }),
        ]),
      },
    });
    // Exactly one backstage ServiceAccount: the IRSA one, not a second plain one.
    const saManifest = String.raw`\"kind\":\"ServiceAccount\",\"metadata\":{\"name\":\"backstage\"`;
    expect(json.split(saManifest).length - 1).toBe(1);
  });

  test('browser-facing ports differ from the self-hosted portal (7107/5656)', () => {
    expect(json).toContain('http://localhost:7108');
    expect(json).toContain('issuer: http://localhost:5657');
    expect(json).not.toMatch(/localhost:(7107|5656)/);
  });

  test('no portal with an external Git host or portal=false', () => {
    for (const tpl of [synth({ provider: 'external' }), synth({ portal: false })]) {
      tpl.resourceCountIs('AWS::EKS::PodIdentityAssociation', 0);
      expect(JSON.stringify(tpl.toJSON())).not.toContain('backstage-app');
    }
  });

  test('Argo CD admin mapping supports users and groups', () => {
    t.hasResourceProperties('AWS::EKS::Capability', {
      Type: 'ARGOCD',
      Configuration: {
        ArgoCd: Match.objectLike({
          RbacRoleMappings: [
            {
              Role: 'ADMIN',
              Identities: [
                { Id: 'group-1', Type: 'SSO_GROUP' },
                { Id: 'user-1', Type: 'SSO_USER' },
              ],
            },
          ],
        }),
      },
    });
    synth({ userOnly: true }).hasResourceProperties('AWS::EKS::Capability', {
      Type: 'ARGOCD',
      Configuration: {
        ArgoCd: Match.objectLike({
          RbacRoleMappings: [{ Role: 'ADMIN', Identities: [{ Id: 'user-1', Type: 'SSO_USER' }] }],
        }),
      },
    });
  });
});

describe('skeleton', () => {
  const data = loadSkeleton({ skeletonDir, repoUrlPrefix: 'https://git-codecommit.r.amazonaws.com/v1/repos/svc-' });

  test('encodes paths as ConfigMap keys and drops Gitea CI', () => {
    expect(Object.keys(data)).toContain('base__chart__values.yaml');
    expect(Object.keys(data)).toContain('langs__node__app__src__index.ts');
    expect(Object.keys(data).some((k) => k.includes('.gitea'))).toBe(false);
  });

  test('service claim points at CodeCommit, ingress disabled', () => {
    const claim = data['base__service-claim.yaml'];
    expect(claim).toContain('repoURL: https://git-codecommit.r.amazonaws.com/v1/repos/svc-${{ values.name }}');
    expect(claim).not.toContain('gitea');
    expect(data['base__chart__values.yaml']).toMatch(/ingress:\n  enabled: false/);
  });

  test('fits in a ConfigMap', () => {
    expect(Buffer.byteLength(JSON.stringify(data))).toBeLessThan(900 * 1024);
  });
});

const platformDir = path.resolve(__dirname, '..', 'platform');
const seedValues = {
  REGION: 'eu-central-1',
  CLUSTER_NAME: 'test',
  SERVICE_REPO_PREFIX: 'svc-',
  SCAFFOLD_IMAGE,
};

describe('platform repo seed', () => {
  const dir = stagePlatformSeed(platformDir, seedValues);

  test('copies platform/ and fills every placeholder', () => {
    const tpl = fs.readFileSync(path.join(dir, 'backstage/template.yaml'), 'utf8');
    expect(tpl).not.toContain('@@');
    expect(tpl).toContain(`image: "${SCAFFOLD_IMAGE}"`);
    expect(fs.existsSync(path.join(dir, 'apis/service-rgd.yaml'))).toBe(true);
    expect(fs.existsSync(path.join(dir, 'crds/downstream-crds.yaml'))).toBe(true);
  });

  test('is stable across synths (same dir, same asset hash)', () => {
    expect(stagePlatformSeed(platformDir, seedValues)).toBe(dir);
  });

  test('rejects unknown placeholders and deploy-time tokens', () => {
    const { REGION, ...missing } = seedValues;
    expect(() => stagePlatformSeed(platformDir, missing)).toThrow(/Unknown placeholder @@REGION@@/);
    expect(() => stagePlatformSeed(platformDir, { ...seedValues, REGION: cdk.Aws.REGION })).toThrow(/synth time/);
  });

  test('Argo CD syncs the repo but not backstage/', () => {
    const json = JSON.stringify(synth().toJSON());
    expect(json).toContain(String.raw`\"directory\":{\"recurse\":true,\"exclude\":\"backstage/*\"}`);
  });
});

describe('Backstage template (platform/backstage/template.yaml)', () => {
  const tpl = parse(fs.readFileSync(path.join(stagePlatformSeed(platformDir, seedValues), 'backstage/template.yaml'), 'utf8'));

  test('is a scaffolder template', () => {
    expect(tpl.apiVersion).toBe('scaffolder.backstage.io/v1beta3');
    expect(tpl.kind).toBe('Template');
  });

  test('creates the repo Job, the namespace, then the Argo CD app', () => {
    const applies = tpl.spec.steps.filter((s: any) => s.action === 'cnoe:kubernetes:apply').map((s: any) => s.id);
    expect(applies).toEqual(['apply-repo', 'apply-namespace', 'apply-argo-app']);
    const app = tpl.spec.steps.find((s: any) => s.id === 'serialize-argo-app').input.data;
    expect(app.spec.destination.name).toBe('in-cluster');
    expect(app.spec.source.repoURL).toBe(
      'https://git-codecommit.eu-central-1.amazonaws.com/v1/repos/svc-${{ parameters.name }}',
    );
    const job = tpl.spec.steps.find((s: any) => s.id === 'serialize-repo').input.data;
    expect(job.spec.template.spec.serviceAccountName).toBe('repo-scaffolder');
    expect(job.spec.template.spec.containers[0].env).toEqual(
      expect.arrayContaining([
        { name: 'REPO_PREFIX', value: 'svc-' },
        { name: 'AWS_REGION', value: 'eu-central-1' },
      ]),
    );
  });

  test('registers the new component from a console-style CodeCommit URL', () => {
    const reg = tpl.spec.steps.find((s: any) => s.action === 'catalog:register');
    expect(reg.input).toEqual({
      catalogInfoUrl:
        'https://eu-central-1.console.aws.amazon.com/codesuite/codecommit/repositories/svc-${{ parameters.name }}/browse/refs/heads/main/--/catalog-info.yaml',
      optional: true,
    });
  });
});

describe('Backstage reads the template from the platform repo', () => {
  const t = synth();
  const json = JSON.stringify(t.toJSON());

  test('catalog location is the platform repo, no template ConfigMap', () => {
    expect(json).toContain('/browse/refs/heads/main/--/backstage/template.yaml');
    expect(json).not.toContain('backstage-templates');
  });

  test('IRSA role can read the platform repo', () => {
    t.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: ['codecommit:GetFile', 'codecommit:GetFolder'],
            Resource: Match.arrayWith([{ 'Fn::GetAtt': [Match.stringLikeRegexp('GitPlatformRepo'), 'Arn'] }]),
          }),
        ]),
      },
    });
  });
});
