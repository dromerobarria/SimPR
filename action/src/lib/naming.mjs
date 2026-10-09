// Deterministic artifact naming.
//
// With `archive: false`, actions/upload-artifact uses the uploaded file name as
// the artifact name, so the name includes the `.zip` extension.

export const ARTIFACT_PREFIX = 'simpr-pr-';

const NAME_RE = /^simpr-pr-(\d+)-([0-9a-f]{8,64})\.zip$/;

export function artifactName(prNumber, contentKey) {
  assertPrNumber(prNumber);
  if (!/^[0-9a-f]{8,64}$/.test(contentKey)) {
    throw new Error(`Invalid content key: ${contentKey}`);
  }
  return `${ARTIFACT_PREFIX}${prNumber}-${contentKey}.zip`;
}

/** Returns `{ pr, contentKey }` for SimPR artifact names, otherwise `null`. */
export function parseArtifactName(name) {
  const match = NAME_RE.exec(name ?? '');
  if (!match) return null;
  return { pr: Number(match[1]), contentKey: match[2] };
}

export function prPrefix(prNumber) {
  assertPrNumber(prNumber);
  return `${ARTIFACT_PREFIX}${prNumber}-`;
}

export function assertPrNumber(value) {
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n <= 0 || String(n) !== String(value).trim()) {
    throw new Error(`Invalid pull request number: ${value}`);
  }
  return n;
}
