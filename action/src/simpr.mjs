#!/usr/bin/env node
// SimPR action entry point. Every input arrives through environment variables
// (never through `${{ }}` interpolation into shell code).
//
// Usage: node simpr.mjs <command>
//   key              compute the content key and artifact name
//   find-existing    look up a live build with the same content key
//   package          stage the built .app with simpr.json and zip it
//   write-meta       write simpr-meta.json (what `publish` needs)
//   publish          create/update the sticky comment and delete superseded builds
//   publish-from-run publish for a build that ran in another (untrusted) workflow run
//   cleanup          delete all builds of a closed PR and mark the comment expired
//   sweep            delete orphaned and old builds across the repository

import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, statSync, readdirSync, rmSync, appendFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, basename, resolve, dirname } from 'node:path';

import { computeContentKey, parseList } from './lib/contentKey.mjs';
import { artifactName, assertPrNumber, parseArtifactName } from './lib/naming.mjs';
import { createClient, repoApi } from './lib/github.mjs';
import { validateManifest, folderNameFor, MANIFEST_SCHEMA_VERSION, SHA_RE } from './lib/manifest.mjs';
import {
  renderReadyComment,
  renderExpiredComment,
  findStickyComment,
  parseState,
} from './lib/comment.mjs';
import { selectSuperseded, selectForSweep, artifactsForPr } from './lib/prune.mjs';

const env = process.env;

// ---------- helpers ----------

function log(message) {
  process.stdout.write(`${message}\n`);
}

function warn(message) {
  process.stdout.write(`::warning::${message}\n`);
}

function setOutput(name, value) {
  const file = env.GITHUB_OUTPUT;
  const text = String(value ?? '');
  if (!file) {
    log(`[output] ${name}=${text}`);
    return;
  }
  const delimiter = `SIMPR_EOF_${Math.random().toString(36).slice(2)}`;
  appendFileSync(file, `${name}<<${delimiter}\n${text}\n${delimiter}\n`);
}

function summary(markdown) {
  if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `${markdown}\n`);
}

function required(name) {
  const value = env[name];
  if (value === undefined || value === '') throw new Error(`Missing required environment variable ${name}`);
  return value;
}

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options }).trim();
}

function tryRun(cmd, args, options = {}) {
  try {
    return run(cmd, args, options);
  } catch {
    return null;
  }
}

function api() {
  const token = required('SIMPR_TOKEN');
  const client = createClient({ token, apiUrl: env.GITHUB_API_URL || 'https://api.github.com' });
  return repoApi(client, required('GITHUB_REPOSITORY'));
}

function serverUrl() {
  return env.GITHUB_SERVER_URL || 'https://github.com';
}

function intEnv(name, fallback) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${name} must be a non-negative integer, got "${raw}"`);
  return n;
}

function buildSettings() {
  return {
    workspace: env.SIMPR_WORKSPACE,
    project: env.SIMPR_PROJECT,
    scheme: env.SIMPR_SCHEME,
    configuration: env.SIMPR_CONFIGURATION,
    extraArgs: env.SIMPR_EXTRA_XCODEBUILD_ARGS,
    archs: env.SIMPR_ARCHS,
    salt: env.SIMPR_KEY_SALT,
  };
}

/** Downloads an artifact zip (served raw because it was uploaded with archive: false). */
async function downloadArtifact(repo, artifactId, dest) {
  const location = await repo.artifactDownloadUrl(artifactId);
  // The signed URL needs no token; never forward the GitHub token to it.
  const res = await fetch(location);
  if (!res.ok) throw new Error(`Downloading artifact ${artifactId} failed with ${res.status}`);
  writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
}

/** Extracts a zip with ditto and returns the directory. Handles a wrapping zip layer. */
function extractZip(zipPath) {
  const dir = mkdtempSync(join(tmpdir(), 'simpr-x-'));
  if (process.platform === 'darwin') run('ditto', ['-x', '-k', zipPath, dir]);
  else run('unzip', ['-q', zipPath, '-d', dir]);
  const entries = readdirSync(dir);
  if (entries.length === 1 && entries[0].endsWith('.zip')) {
    return extractZip(join(dir, entries[0]));
  }
  return dir;
}

function findManifest(dir, depth = 2) {
  const direct = join(dir, 'simpr.json');
  if (existsSync(direct)) return direct;
  if (depth === 0) return null;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory() && !entry.name.endsWith('.app')) {
      const found = findManifest(join(dir, entry.name), depth - 1);
      if (found) return found;
    }
  }
  return null;
}

function artifactInfo(a) {
  return {
    id: a.id,
    name: a.name,
    runId: a.workflow_run?.id,
    sizeBytes: a.size_in_bytes,
    expiresAt: a.expires_at,
    createdAt: a.created_at,
  };
}

// ---------- commands ----------

async function cmdKey() {
  const pr = assertPrNumber(required('SIMPR_PR'));
  const root = run('git', ['rev-parse', '--show-toplevel']);
  const { key, inputs } = computeContentKey({
    appPaths: parseList(env.SIMPR_APP_PATHS),
    settings: buildSettings(),
    revParse: (rev) => tryRun('git', ['rev-parse', '--verify', '--quiet', rev], { cwd: root }),
    lsFiles: () => run('git', ['ls-files', '-z'], { cwd: root }).split('\0').filter(Boolean),
  });
  log(`Content key inputs:\n  ${inputs.join('\n  ')}`);
  log(`Content key: ${key}`);
  setOutput('content-key', key);
  setOutput('artifact-name', artifactName(pr, key));
}

async function cmdFindExisting() {
  const name = required('SIMPR_ARTIFACT_NAME');
  const repo = api();
  const live = (await repo.findArtifactsByName(name))
    .filter((a) => !a.expired && a.workflow_run?.id)
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));

  if (live.length === 0) {
    log(`No live build named ${name}; building.`);
    setOutput('exists', 'false');
    return;
  }

  const artifact = live[0];
  const workDir = mkdtempSync(join(tmpdir(), 'simpr-existing-'));
  const zip = join(workDir, 'build.zip');
  try {
    await downloadArtifact(repo, artifact.id, zip);
    const manifestPath = findManifest(extractZip(zip));
    if (!manifestPath) throw new Error('simpr.json not found in the existing build');
    const manifest = validateManifest(JSON.parse(readFileSync(manifestPath, 'utf8')));
    const out = join(workDir, 'simpr.json');
    writeFileSync(out, JSON.stringify(manifest, null, 2));
    log(`Reusing build ${artifact.name} (artifact ${artifact.id}, run ${artifact.workflow_run.id}).`);
    setOutput('exists', 'true');
    setOutput('manifest-path', out);
    setOutput('artifact-json', JSON.stringify(artifactInfo(artifact)));
  } catch (e) {
    warn(`Found ${name} but couldn't reuse it (${e.message}); building again.`);
    setOutput('exists', 'false');
  }
}

function plistJson(path) {
  return JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path]));
}

function dirSize(path) {
  return Number(run('du', ['-sk', path]).split(/\s+/)[0]) * 1024;
}

function xcodeInfo() {
  const text = tryRun('xcodebuild', ['-version']) ?? '';
  const version = /Xcode\s+([\d.]+)/.exec(text)?.[1] ?? 'unknown';
  const build = /Build version\s+(\S+)/.exec(text)?.[1] ?? null;
  const sdk = tryRun('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-version']) ?? 'unknown';
  return { version, build, sdk };
}

async function cmdPackage() {
  const appPath = resolve(required('SIMPR_APP_PATH'));
  const outDir = resolve(required('SIMPR_OUTPUT_DIR'));
  const pr = assertPrNumber(required('SIMPR_PR'));
  const sha = required('SIMPR_SHA');
  const repository = required('GITHUB_REPOSITORY');
  const contentKey = required('SIMPR_CONTENT_KEY');
  if (!SHA_RE.test(sha)) throw new Error(`SIMPR_SHA must be a full commit SHA, got ${sha}`);

  const info = plistJson(join(appPath, 'Info.plist'));
  const executable = join(appPath, info.CFBundleExecutable);
  const archs = run('lipo', ['-archs', executable]).split(/\s+/).filter((a) => a === 'arm64' || a === 'x86_64');
  const xcode = xcodeInfo();
  const appName = info.CFBundleDisplayName || info.CFBundleName || basename(appPath, '.app');
  const folderName = folderNameFor(appName, pr, sha);

  const manifest = validateManifest({
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    bundleId: info.CFBundleIdentifier,
    appName,
    appBundleName: basename(appPath),
    folderName,
    version: info.CFBundleShortVersionString ?? null,
    buildNumber: info.CFBundleVersion ?? null,
    minimumOSVersion: info.MinimumOSVersion,
    architectures: archs,
    xcodeVersion: xcode.version,
    xcodeBuild: xcode.build,
    sdkVersion: xcode.sdk,
    configuration: env.SIMPR_CONFIGURATION || null,
    scheme: env.SIMPR_SCHEME || null,
    repository,
    prNumber: pr,
    commitSha: sha,
    contentKey,
    buildDate: new Date().toISOString(),
    appSizeBytes: dirSize(appPath),
  });

  const staging = join(mkdtempSync(join(tmpdir(), 'simpr-stage-')), folderName);
  mkdirSync(staging, { recursive: true });
  run('ditto', [appPath, join(staging, basename(appPath))]);
  writeFileSync(join(staging, 'simpr.json'), `${JSON.stringify(manifest, null, 2)}\n`);

  mkdirSync(outDir, { recursive: true });
  const zipPath = join(outDir, artifactName(pr, contentKey));
  rmSync(zipPath, { force: true });
  // --keepParent keeps the folder at the zip root; ditto preserves symlinks and the executable bit.
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', staging, zipPath]);

  const manifestPath = join(outDir, 'simpr.json');
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  log(`Packaged ${manifest.appBundleName} (${archs.join(', ')}, iOS ${manifest.minimumOSVersion}+) into ${zipPath}`);
  setOutput('zip-path', zipPath);
  setOutput('manifest-path', manifestPath);
  setOutput('architectures', archs.join(','));
}

async function cmdWriteMeta() {
  const manifest = validateManifest(JSON.parse(readFileSync(required('SIMPR_MANIFEST_PATH'), 'utf8')));
  const out = resolve(required('SIMPR_META_PATH'));
  const reused = env.SIMPR_REUSED === 'true';
  let artifact;
  if (reused) {
    artifact = JSON.parse(required('SIMPR_ARTIFACT_JSON'));
  } else {
    const id = Number(required('SIMPR_ARTIFACT_ID'));
    const zipPath = env.SIMPR_ZIP_PATH;
    artifact = {
      id,
      name: zipPath ? basename(zipPath) : null,
      runId: Number(required('GITHUB_RUN_ID')),
      sizeBytes: zipPath ? statSync(zipPath).size : null,
      expiresAt: null,
    };
    try {
      const { data } = await createClient({
        token: required('SIMPR_TOKEN'),
        apiUrl: env.GITHUB_API_URL || 'https://api.github.com',
      }).request('GET', `/repos/${required('GITHUB_REPOSITORY')}/actions/artifacts/${id}`);
      artifact = { ...artifact, ...artifactInfo(data) };
    } catch (e) {
      warn(`Couldn't read artifact ${id} details: ${e.message}`);
    }
  }
  const meta = { schemaVersion: 1, reused, manifest, artifact };
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(meta, null, 2)}\n`);
  log(`Wrote ${out}`);
}

function validateMeta(meta) {
  if (!meta || meta.schemaVersion !== 1) throw new Error('Unsupported simpr-meta.json');
  const manifest = validateManifest(meta.manifest);
  const a = meta.artifact ?? {};
  for (const field of ['id', 'runId']) {
    if (!Number.isSafeInteger(a[field]) || a[field] <= 0) throw new Error(`artifact.${field} is invalid`);
  }
  if (!parseArtifactName(a.name)) throw new Error(`artifact.name is not a SimPR artifact: ${a.name}`);
  if (parseArtifactName(a.name).pr !== manifest.prNumber) throw new Error('artifact name and PR number disagree');
  return { manifest, artifact: a, reused: meta.reused === true };
}

async function upsertComment(repo, pr, body) {
  const comments = await repo.listIssueComments(pr);
  const existing = findStickyComment(comments, { authorLogin: env.SIMPR_COMMENT_AUTHOR || undefined });
  if (existing) {
    if (existing.body === body) return existing;
    try {
      return await repo.updateComment(existing.id, body);
    } catch (e) {
      if (e.status !== 403 && e.status !== 404) throw e;
      warn(`Couldn't edit comment ${existing.id} (${e.status}); posting a new one.`);
    }
  }
  return repo.createComment(pr, body);
}

async function publish(meta, repo) {
  const { manifest, artifact, reused } = validateMeta(meta);
  const pr = manifest.prNumber;
  if (manifest.repository !== repo.repository) {
    throw new Error(`Build is for ${manifest.repository}, not ${repo.repository}`);
  }

  const body = renderReadyComment({
    manifest,
    artifact,
    redirectBaseUrl: required('SIMPR_REDIRECT_BASE_URL'),
    serverUrl: serverUrl(),
    reused,
  });
  const comment = await upsertComment(repo, pr, body);
  log(`Comment: ${comment.html_url}`);
  setOutput('comment-url', comment.html_url);

  const keep = intEnv('SIMPR_KEEP_BUILDS', 1) || 1;
  const all = await repo.listArtifacts({ maxPages: intEnv('SIMPR_MAX_PAGES', 10) });
  const superseded = selectSuperseded(all, { pr, keep, currentId: artifact.id });
  for (const a of superseded) {
    const deleted = await repo.deleteArtifact(a.id);
    log(`${deleted ? 'Deleted' : 'Already gone:'} superseded build ${a.name} (artifact ${a.id})`);
  }

  summary(
    `### SimPR\n\n${reused ? 'Reused' : 'Built'} \`${artifact.name}\` for PR #${pr} ` +
      `(${manifest.architectures.join(', ')}, iOS ${manifest.minimumOSVersion}+). ` +
      `[Comment](${comment.html_url}). Deleted ${superseded.length} superseded build(s).`,
  );
}

async function cmdPublish() {
  const meta = JSON.parse(readFileSync(required('SIMPR_META_PATH'), 'utf8'));
  await publish(meta, api());
}

/**
 * Trusted half of the fork-safe pattern. Runs on `workflow_run`, downloads
 * simpr-meta.json from the untrusted run, treats it purely as data, and checks
 * it against facts GitHub reports about that run before commenting.
 */
async function cmdPublishFromRun() {
  const runId = Number(required('SIMPR_SOURCE_RUN_ID'));
  const repo = api();
  const sourceRun = await repo.getRun(runId);
  if (!sourceRun) throw new Error(`Run ${runId} not found`);
  if (sourceRun.conclusion !== 'success') {
    log(`Run ${runId} concluded "${sourceRun.conclusion}"; nothing to publish.`);
    return;
  }

  const metaArtifact = (await repo.listRunArtifacts(runId)).find((a) => a.name === 'simpr-meta.json' && !a.expired);
  if (!metaArtifact) {
    log(`Run ${runId} has no simpr-meta.json; nothing to publish.`);
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), 'simpr-meta-'));
  const file = join(dir, 'simpr-meta.json');
  await downloadArtifact(repo, metaArtifact.id, file);
  let raw = readFileSync(file);
  if (raw.subarray(0, 2).toString() === 'PK') {
    raw = readFileSync(join(extractZip(file), 'simpr-meta.json'));
  }
  if (raw.length > 64 * 1024) throw new Error('simpr-meta.json is unexpectedly large');
  const meta = JSON.parse(raw.toString('utf8'));
  const { manifest, artifact } = validateMeta(meta);

  // Never trust the PR number or SHA claimed by the untrusted run: confirm them.
  const pull = await repo.getPull(manifest.prNumber);
  if (pull.head.sha !== sourceRun.head_sha || manifest.commitSha !== sourceRun.head_sha) {
    throw new Error(
      `simpr-meta.json claims PR #${manifest.prNumber} at ${manifest.commitSha}, ` +
        `but run ${runId} built ${sourceRun.head_sha} and the PR head is ${pull.head.sha}. Refusing to publish.`,
    );
  }
  if (pull.state !== 'open') {
    log(`PR #${manifest.prNumber} is ${pull.state}; not publishing.`);
    return;
  }
  // The build artifact must belong to this repo and to the run (or to an earlier run when reused).
  const real = (await repo.findArtifactsByName(artifact.name)).find((a) => a.id === artifact.id);
  if (!real) throw new Error(`Artifact ${artifact.id} (${artifact.name}) not found in ${repo.repository}`);
  meta.artifact = { ...artifact, ...artifactInfo(real) };
  await publish(meta, repo);
}

async function cmdCleanup() {
  const pr = assertPrNumber(required('SIMPR_PR'));
  const reason = env.SIMPR_MERGED === 'true' ? 'merged' : 'closed';
  const repo = api();

  const all = await repo.listArtifacts({ maxPages: intEnv('SIMPR_MAX_PAGES', 10) });
  const mine = artifactsForPr(all, pr);
  for (const a of mine) {
    await repo.deleteArtifact(a.id);
    log(`Deleted ${a.name} (artifact ${a.id})`);
  }

  const comments = await repo.listIssueComments(pr);
  const existing = findStickyComment(comments, { authorLogin: env.SIMPR_COMMENT_AUTHOR || undefined });
  if (existing) {
    const previous = parseState(existing.body);
    if (previous?.status !== 'expired') {
      await repo.updateComment(existing.id, renderExpiredComment({ reason, previousState: previous }));
      log(`Marked comment ${existing.id} as expired (${reason}).`);
    }
  }
  summary(`### SimPR cleanup\n\nPR #${pr} was ${reason}. Deleted ${mine.length} build(s).`);
}

async function cmdSweep() {
  const repo = api();
  const maxAgeDays = intEnv('SIMPR_MAX_AGE_DAYS', 30);
  const dryRun = env.SIMPR_DRY_RUN === 'true';
  const all = await repo.listArtifacts({ maxPages: intEnv('SIMPR_MAX_PAGES', 50) });

  const prStates = new Map();
  for (const pr of new Set(all.map((a) => parseArtifactName(a.name)?.pr).filter(Boolean))) {
    try {
      const pull = await repo.getPull(pr);
      prStates.set(pr, pull.state === 'open' ? 'open' : pull.merged_at ? 'merged' : 'closed');
    } catch (e) {
      if (e.status !== 404) throw e;
      prStates.set(pr, 'missing');
    }
  }

  const doomed = selectForSweep(all, { prStates, maxAgeDays, now: new Date() });
  for (const { artifact, reason } of doomed) {
    log(`${dryRun ? '[dry run] would delete' : 'Deleting'} ${artifact.name} (artifact ${artifact.id}): ${reason}`);
    if (!dryRun) await repo.deleteArtifact(artifact.id);
  }

  // Tell open PRs whose build is gone (retention or max age) how to rebuild.
  const deletedIds = new Set(dryRun ? [] : doomed.map((d) => d.artifact.id));
  const liveIds = new Set(all.filter((a) => !a.expired && !deletedIds.has(a.id)).map((a) => a.id));
  let updated = 0;
  for (const [pr, state] of prStates) {
    if (state !== 'open') continue;
    const comments = await repo.listIssueComments(pr);
    const existing = findStickyComment(comments, { authorLogin: env.SIMPR_COMMENT_AUTHOR || undefined });
    const prev = parseState(existing?.body);
    if (!existing || prev?.status !== 'ready' || liveIds.has(prev.artifactId)) continue;
    // Not in the scanned pages: confirm with the API before declaring it gone.
    const current = deletedIds.has(prev.artifactId) ? null : await repo.getArtifact(prev.artifactId);
    if (current && !current.expired) continue;
    const reason = doomed.some((d) => d.artifact.id === prev.artifactId && d.reason === 'max-age') ? 'maxAge' : 'retention';
    log(`${dryRun ? '[dry run] would mark' : 'Marking'} PR #${pr} comment as expired (${reason}).`);
    if (!dryRun) await repo.updateComment(existing.id, renderExpiredComment({ reason, previousState: prev }));
    updated++;
  }

  summary(`### SimPR sweep\n\n${dryRun ? 'Would delete' : 'Deleted'} ${doomed.length} build(s); updated ${updated} comment(s).`);
}

const commands = {
  key: cmdKey,
  'find-existing': cmdFindExisting,
  package: cmdPackage,
  'write-meta': cmdWriteMeta,
  publish: cmdPublish,
  'publish-from-run': cmdPublishFromRun,
  cleanup: cmdCleanup,
  sweep: cmdSweep,
};

const name = process.argv[2];
const command = commands[name];
if (!command) {
  process.stderr.write(`Unknown command "${name}". Expected one of: ${Object.keys(commands).join(', ')}\n`);
  process.exit(2);
}
command().catch((e) => {
  process.stdout.write(`::error::${e.message}\n`);
  process.exit(1);
});

