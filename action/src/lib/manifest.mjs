// simpr.json: the build manifest stored inside every build zip.
// The Mac app decodes the same schema (see mac-app/Sources/SimPRCore/Manifest.swift).

export const MANIFEST_SCHEMA_VERSION = 1;

const REQUIRED_STRINGS = [
  'bundleId',
  'appName',
  'appBundleName',
  'folderName',
  'minimumOSVersion',
  'commitSha',
  'contentKey',
  'repository',
  'buildDate',
];

export const BUNDLE_ID_RE = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;
export const REPO_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/;
export const SHA_RE = /^[0-9a-f]{40}$/;
export const VERSION_RE = /^\d+(\.\d+){0,2}$/;
export const ARCHS = new Set(['arm64', 'x86_64']);

/** Throws with a list of problems if the manifest is not valid. Returns the manifest. */
export function validateManifest(m) {
  const problems = [];
  if (!m || typeof m !== 'object') throw new Error('Manifest must be a JSON object');
  if (m.schemaVersion !== MANIFEST_SCHEMA_VERSION) problems.push(`schemaVersion must be ${MANIFEST_SCHEMA_VERSION}`);
  for (const key of REQUIRED_STRINGS) {
    if (typeof m[key] !== 'string' || m[key].length === 0) problems.push(`${key} is required`);
  }
  if (m.bundleId && !BUNDLE_ID_RE.test(m.bundleId)) problems.push(`bundleId is invalid: ${m.bundleId}`);
  if (m.repository && !REPO_RE.test(m.repository)) problems.push(`repository is invalid: ${m.repository}`);
  if (m.commitSha && !SHA_RE.test(m.commitSha)) problems.push('commitSha must be a full 40-character SHA');
  if (m.minimumOSVersion && !VERSION_RE.test(m.minimumOSVersion)) problems.push('minimumOSVersion is invalid');
  if (m.appBundleName && !/^[^/]+\.app$/.test(m.appBundleName)) problems.push('appBundleName must end in .app');
  if (m.folderName && (!/^[A-Za-z0-9._-]+$/.test(m.folderName) || /^\.+$/.test(m.folderName))) problems.push('folderName is invalid');
  if (!Array.isArray(m.architectures) || m.architectures.length === 0 || !m.architectures.every((a) => ARCHS.has(a))) {
    problems.push('architectures must list arm64 and/or x86_64');
  }
  if (m.prNumber !== undefined && m.prNumber !== null && !(Number.isSafeInteger(m.prNumber) && m.prNumber > 0)) {
    problems.push('prNumber must be a positive integer');
  }
  if (problems.length) throw new Error(`Invalid simpr.json: ${problems.join('; ')}`);
  return m;
}

/** Folder name used inside the zip. Safe for shells and file systems. */
export function folderNameFor(appName, prNumber, sha) {
  const base = String(appName).replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'App';
  return `${base}-PR${prNumber}-${sha.slice(0, 7)}`;
}
