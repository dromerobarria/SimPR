// Pure selection logic for deleting builds. Callers do the API calls.

import { parseArtifactName } from './naming.mjs';

const byNewest = (a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id;

/** SimPR artifacts belonging to a PR, newest first. */
export function artifactsForPr(artifacts, pr) {
  return artifacts.filter((a) => parseArtifactName(a.name)?.pr === pr).sort(byNewest);
}

/**
 * Builds superseded by a newer build of the same PR.
 * Keeps the current build plus the newest `keep - 1` other unexpired builds.
 */
export function selectSuperseded(artifacts, { pr, keep = 1, currentId }) {
  const keepCount = Math.max(1, Number(keep) || 1);
  const mine = artifactsForPr(artifacts, pr);
  const kept = new Set(currentId ? [currentId] : []);
  for (const a of mine) {
    if (kept.size >= keepCount) break;
    if (!a.expired) kept.add(a.id);
  }
  return mine.filter((a) => !kept.has(a.id));
}

/**
 * Builds to delete in the scheduled sweep.
 *
 * @param {object[]} artifacts  repository artifacts (any name; non-SimPR ones are ignored)
 * @param {object} options
 * @param {Map<number,string>} options.prStates  PR number -> 'open' | 'closed' | 'merged' | 'missing'
 * @param {number} options.maxAgeDays  0 disables the age limit
 * @param {Date} options.now
 * @returns {{ artifact: object, reason: string }[]}
 */
export function selectForSweep(artifacts, { prStates, maxAgeDays = 0, now = new Date() }) {
  const out = [];
  const maxAgeMs = maxAgeDays > 0 ? maxAgeDays * 86_400_000 : Infinity;
  for (const a of artifacts) {
    const parsed = parseArtifactName(a.name);
    if (!parsed) continue;
    const state = prStates.get(parsed.pr) ?? 'missing';
    let reason = null;
    if (state !== 'open') reason = `pr-${state}`;
    else if (!a.workflow_run?.id) reason = 'run-missing';
    else if (a.expired) reason = 'expired';
    else if (now.getTime() - Date.parse(a.created_at) > maxAgeMs) reason = 'max-age';
    if (reason) out.push({ artifact: a, reason });
  }
  return out;
}
