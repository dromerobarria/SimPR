// Content key: a short hash of everything that can change the built app.
//
// The key combines the git object hashes of the configured app paths, every
// tracked dependency lockfile, and the build settings. Git object hashes are
// content addresses, so the key only changes when those inputs change, no
// matter how many commits, merges or re-runs happen in between.

import { createHash } from 'node:crypto';

export const KEY_VERSION = 'v1';

export const LOCKFILE_NAMES = [
  'Package.resolved',
  'Podfile.lock',
  'Cartfile.resolved',
  'Mintfile',
];

/** Splits a multi-line or comma-separated input into trimmed, unique entries. */
export function parseList(input) {
  if (!input) return [];
  const items = String(input)
    .split(/[\n,]/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && !s.startsWith('#'));
  return [...new Set(items)];
}

/** Normalizes a repository-relative path. Rejects paths that escape the repo. */
export function normalizePath(path) {
  let p = path.replace(/\\/g, '/').replace(/\/+/g, '/');
  while (p.startsWith('./')) p = p.slice(2);
  if (p.endsWith('/') && p.length > 1) p = p.slice(0, -1);
  if (p === '' || p === '.') return '.';
  if (p.startsWith('/') || p.split('/').includes('..')) {
    throw new Error(`app-paths entries must be relative to the repository root: ${path}`);
  }
  return p;
}

/** Picks tracked files whose base name is a known lockfile. */
export function findLockfiles(trackedFiles, names = LOCKFILE_NAMES) {
  const wanted = new Set(names);
  return trackedFiles
    .filter((f) => wanted.has(f.split('/').pop()))
    .sort();
}

/**
 * Computes the content key.
 *
 * @param {object} options
 * @param {string[]} options.appPaths   repository-relative paths that affect the app
 * @param {object}   options.settings   build settings that affect the output
 * @param {(rev: string) => string|null} options.revParse  resolves `HEAD:<path>` to an object id, or null
 * @param {() => string[]} options.lsFiles  lists tracked files
 * @returns {{ key: string, inputs: string[] }}
 */
export function computeContentKey({ appPaths, settings = {}, revParse, lsFiles }) {
  const paths = (appPaths.length ? appPaths : ['.']).map(normalizePath);
  const lockfiles = paths.includes('.') ? [] : findLockfiles(lsFiles());
  const all = [...new Set([...paths, ...lockfiles])].sort();

  const inputs = [`version=${KEY_VERSION}`];
  for (const path of all) {
    const rev = path === '.' ? 'HEAD^{tree}' : `HEAD:${path}`;
    inputs.push(`path:${path}=${revParse(rev) ?? 'missing'}`);
  }
  for (const name of Object.keys(settings).sort()) {
    const value = settings[name];
    if (value === undefined || value === null || value === '') continue;
    inputs.push(`setting:${name}=${value}`);
  }

  const key = createHash('sha256').update(inputs.join('\n')).digest('hex').slice(0, 16);
  return { key, inputs };
}
