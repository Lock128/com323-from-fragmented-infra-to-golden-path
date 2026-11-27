import * as crypto from 'crypto';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';

/**
 * Stages the contents the platform CodeCommit repo is seeded with: a copy of
 * platform/ with double-at placeholders (e.g. REGION) replaced. CodeCommit seeds a repo once,
 * on creation, so the values must be known at synth time (no CloudFormation
 * tokens). After that the repo is edited with git.
 *
 * Returns the staging directory, keyed by a content hash so repeated synths
 * reuse it and the CDK asset hash stays stable.
 */
export function stagePlatformSeed(sourceDir: string, values: Record<string, string>): string {
  for (const [key, value] of Object.entries(values)) {
    if (!/^[A-Z_]+$/.test(key)) throw new Error(`Invalid placeholder name: ${key}`);
    if (cdk.Token.isUnresolved(value)) {
      throw new Error(
        `Placeholder @@${key}@@ must be known at synth time (got a token). ` +
          'Set an explicit account/region for the stack.',
      );
    }
  }

  const files = listFiles(sourceDir);
  const rendered = files.map((rel) => {
    const raw = fs.readFileSync(path.join(sourceDir, rel), 'utf8');
    const out = raw.replace(/@@([A-Z_]+)@@/g, (match, key: string) => {
      if (!(key in values)) throw new Error(`Unknown placeholder ${match} in ${rel}`);
      return values[key];
    });
    return { rel, out };
  });

  const hash = crypto.createHash('sha256');
  for (const { rel, out } of rendered) hash.update(rel).update('\0').update(out).update('\0');
  const dir = path.join(os.tmpdir(), 'managed-idp-platform-seed', hash.digest('hex').slice(0, 16));

  // Reuse a staged copy only if every file is still there: OS temp cleaners
  // (e.g. macOS for /var/folders) delete old files but can leave the folders.
  const complete = fs.existsSync(dir) && rendered.every(({ rel }) => fs.existsSync(path.join(dir, rel)));
  if (!complete) {
    fs.rmSync(dir, { recursive: true, force: true });
    const tmp = `${dir}.${process.pid}`;
    for (const { rel, out } of rendered) {
      fs.mkdirSync(path.dirname(path.join(tmp, rel)), { recursive: true });
      fs.writeFileSync(path.join(tmp, rel), out);
    }
    try {
      fs.renameSync(tmp, dir);
    } catch {
      // Another synth won the race; its content is identical.
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
  return dir;
}

function listFiles(root: string, rel = ''): string[] {
  return fs.readdirSync(path.join(root, rel), { withFileTypes: true }).flatMap((e) => {
    const p = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) return listFiles(root, p);
    return e.isFile() ? [p] : [];
  });
}
