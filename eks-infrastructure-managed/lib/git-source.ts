import * as codecommit from 'aws-cdk-lib/aws-codecommit';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export type GitProvider = 'codecommit' | 'external';

export interface GitSourceProps {
  readonly provider: GitProvider;
  /** CodeCommit repository name (provider "codecommit"). */
  readonly repositoryName: string;
  /**
   * Clone URL of a repo you host yourself (provider "external", e.g. GitHub).
   * It must already contain the contents of `platform/`, and Argo CD needs
   * access: public repo, or a repository secret / CodeConnections.
   */
  readonly externalRepoUrl?: string;
  /** Directory the CodeCommit repo's main branch is seeded with (once, on creation). */
  readonly seedDirectory: string;
}

/**
 * The Git host Argo CD syncs the platform definitions from.
 *
 * "codecommit": creates a CodeCommit repo in this account and seeds its `main`
 *   branch with `platform/` (CRDs, the kro ResourceGraphDefinition and the
 *   Backstage template), placeholders filled in by stagePlatformSeed(). The Argo CD
 *   capability reads CodeCommit natively through its IAM role (codecommit:GitPull),
 *   so no repository credentials or secrets exist.
 * "external": only records the URL. GitHub, GitLab or any other host works the
 *   same as far as the rest of the stack is concerned.
 */
export class GitSource extends Construct {
  public readonly repoUrl: string;
  public readonly repository?: codecommit.Repository;

  constructor(scope: Construct, id: string, props: GitSourceProps) {
    super(scope, id);

    if (props.provider === 'codecommit') {
      this.repository = new codecommit.Repository(this, 'PlatformRepo', {
        repositoryName: props.repositoryName,
        description: 'Platform definitions (CRDs + kro RGDs) synced by managed Argo CD',
        // Seeds `main` once, on creation. After that the repo is managed with git.
        code: codecommit.Code.fromDirectory(props.seedDirectory, 'main'),
      });
      this.repoUrl = this.repository.repositoryCloneUrlHttp;
    } else {
      if (!props.externalRepoUrl) {
        throw new Error(
          'managedIdp.externalRepoUrl is required when managedIdp.gitProvider is "external".',
        );
      }
      this.repoUrl = props.externalRepoUrl;
    }
  }

  /** Lets an IAM role (the Argo CD capability role) pull from the repo. No-op for external hosts. */
  public grantPull(role: iam.IRole): void {
    this.repository?.grantPull(role);
  }
}
