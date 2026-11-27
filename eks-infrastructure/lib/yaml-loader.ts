import * as fs from 'fs';
import { parseAllDocuments } from 'yaml';

/**
 * Loads a single-document YAML file into a plain JS object suitable for
 * eks.Cluster#addManifest. Throws if the file holds zero or multiple documents,
 * which keeps the platform manifests honest (one Kubernetes object per file).
 */
export function loadManifest(filePath: string): Record<string, unknown> {
  const docs = loadManifests(filePath);
  if (docs.length !== 1) {
    throw new Error(
      `Expected exactly one YAML document in ${filePath}, found ${docs.length}.`,
    );
  }
  return docs[0];
}

/**
 * Loads a multi-document YAML file (--- separated) into an array of plain JS
 * objects. Empty documents (e.g. trailing ---) are skipped.
 */
export function loadManifests(filePath: string): Record<string, unknown>[] {
  const raw = fs.readFileSync(filePath, 'utf8');
  return parseAllDocuments(raw)
    .map((d) => d.toJS() as Record<string, unknown> | null)
    .filter((o): o is Record<string, unknown> => o !== null && o !== undefined);
}
