import * as fs from 'fs';
import * as path from 'path';

/**
 * Loads the golden-path skeleton from the local demo
 * (local-demo/packages/5-backstage/service-template/skeleton) into ConfigMap
 * data for the scaffold Job. ConfigMap keys cannot contain "/", so each path
 * is encoded with "__" (base/chart/values.yaml -> base__chart__values.yaml).
 *
 * Adjustments for the managed variant:
 *  - .gitea/ (Gitea Actions CI) is dropped: CodeCommit does not run it.
 *  - service-claim.yaml points repoURL at the CodeCommit repo.
 *  - The nginx Ingress is disabled: the EKS cluster has no ingress-nginx.
 */
export interface SkeletonOptions {
  readonly skeletonDir: string;
  /** Clone URL prefix, e.g. https://git-codecommit.<region>.amazonaws.com/v1/repos/svc- */
  readonly repoUrlPrefix: string;
}

const GITEA_CLAIM_URL =
  'http://my-gitea-http.gitea.svc.cluster.local:3000/lockhead/${{ values.name }}.git';

export function loadSkeleton(opts: SkeletonOptions): Record<string, string> {
  const data: Record<string, string> = {};
  const walk = (dir: string, rel: string[]) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === '.gitea') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full, [...rel, entry.name]);
      } else if (entry.isFile()) {
        const relPath = [...rel, entry.name].join('/');
        data[relPath.split('/').join('__')] = patch(relPath, fs.readFileSync(full, 'utf8'), opts);
      }
    }
  };
  walk(opts.skeletonDir, []);
  for (const key of Object.keys(data)) {
    if (!/^[-._a-zA-Z0-9]+$/.test(key)) {
      throw new Error(`Skeleton path cannot be a ConfigMap key: ${key}`);
    }
  }
  return data;
}

function patch(relPath: string, content: string, opts: SkeletonOptions): string {
  if (relPath === 'base/service-claim.yaml') {
    if (!content.includes(GITEA_CLAIM_URL)) {
      throw new Error('service-claim.yaml no longer contains the expected Gitea repoURL; update service-skeleton.ts');
    }
    const body = content.slice(content.indexOf('apiVersion:'));
    return (
      '# The Service the platform applies after the repo exists. Argo CD syncs this\n' +
      '# file; kro composes it into the Argo CD Application, the ECR repository (ACK)\n' +
      '# and the security, SRE and reporting registrations.\n' +
      '# repoURL is the CodeCommit repo the platform created for this service.\n' +
      body.replace(GITEA_CLAIM_URL, `${opts.repoUrlPrefix}\${{ values.name }}`)
    );
  }
  if (relPath === 'base/chart/values.yaml') {
    return content.replace(/ingress:\n  enabled: true/, 'ingress:\n  enabled: false');
  }
  return content;
}
