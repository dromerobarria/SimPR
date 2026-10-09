// Runs the real CLI against the fake GitHub API.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { startFakeGitHub } from './fakeGitHub.mjs';
import { manifest as manifestFixture } from './fixtures.mjs';
import { COMMENT_MARKER, parseState } from '../src/lib/comment.mjs';

const execFileAsync = promisify(execFile);
const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'simpr.mjs');
const isMac = process.platform === 'darwin';

let gh;
before(async () => {
  gh = await startFakeGitHub();
});
after(() => gh.close());

async function cli(command, extraEnv) {
  const work = mkdtempSync(join(tmpdir(), 'simpr-cli-'));
  const outputFile = join(work, 'output');
  writeFileSync(outputFile, '');
  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    GITHUB_REPOSITORY: 'octo/sample',
    GITHUB_API_URL: gh.url,
    GITHUB_SERVER_URL: 'https://github.com',
    GITHUB_OUTPUT: outputFile,
    SIMPR_TOKEN: 'test-token',
    SIMPR_REDIRECT_BASE_URL: 'https://octo.github.io/sample/',
    ...extraEnv,
  };
  let stdout;
  try {
    ({ stdout } = await execFileAsync(process.execPath, [CLI, command], { env }));
  } catch (e) {
    throw new Error(`${command} failed:\n${e.stdout}\n${e.stderr}`);
  }
  const outputs = {};
  const text = readFileSync(outputFile, 'utf8');
  for (const m of text.matchAll(/^([\w-]+)<<(SIMPR_EOF_\w+)\n([\s\S]*?)\n\2$/gm)) outputs[m[1]] = m[3];
  return { stdout, outputs, work };
}

function writeMeta(dir, { manifest = manifestFixture, artifact, reused = false }) {
  const file = join(dir, 'simpr-meta.json');
  writeFileSync(file, JSON.stringify({ schemaVersion: 1, reused, manifest, artifact }));
  return file;
}

/** Builds a minimal fake simulator .app with a universal Mach-O executable. */
function fakeApp(dir) {
  const app = join(dir, 'SampleApp.app');
  mkdirSync(app, { recursive: true });
  const src = join(dir, 'main.c');
  writeFileSync(src, 'int main(void) { return 0; }\n');
  execFileSync('clang', ['-arch', 'arm64', '-arch', 'x86_64', '-o', join(app, 'SampleApp'), src]);
  writeFileSync(
    join(app, 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SampleApp</string>
<key>CFBundleIdentifier</key><string>dev.simpr.SampleApp</string>
<key>CFBundleName</key><string>SampleApp</string>
<key>CFBundleDisplayName</key><string>Sample App</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>34</string>
<key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>`,
  );
  return app;
}

test('publish creates one sticky comment, then edits it, and deletes superseded builds', async () => {
  gh.state.pulls.set(42, { number: 42, state: 'open', head: { sha: manifestFixture.commitSha } });
  const old = gh.addArtifact({ name: 'simpr-pr-42-1111111111111111.zip', workflow_run: { id: 1 }, created_at: '2026-10-01T00:00:00Z' });
  const other = gh.addArtifact({ name: 'simpr-pr-7-1111111111111111.zip', workflow_run: { id: 1 } });
  const current = gh.addArtifact({ name: 'simpr-pr-42-0123456789abcdef.zip', workflow_run: { id: 555 } });
  const artifact = { id: current.id, name: current.name, runId: 555, sizeBytes: 1000 };

  const dir = mkdtempSync(join(tmpdir(), 'simpr-meta-'));
  const first = await cli('publish', { SIMPR_META_PATH: writeMeta(dir, { artifact }) });
  assert.match(first.outputs['comment-url'], /issuecomment-/);

  const ids = gh.state.artifacts.map((a) => a.id);
  assert.ok(!ids.includes(old.id), 'superseded build deleted');
  assert.ok(ids.includes(current.id) && ids.includes(other.id), 'current build and other PRs untouched');

  await cli('publish', { SIMPR_META_PATH: writeMeta(dir, { artifact, reused: true }) });
  const comments = gh.state.comments.filter((c) => c.issue === 42);
  assert.equal(comments.length, 1, 'still a single sticky comment');
  assert.ok(comments[0].body.startsWith(COMMENT_MARKER));
  assert.match(comments[0].body, /existing build was reused/);
  assert.equal(parseState(comments[0].body).artifactId, current.id);
});

test('cleanup deletes every build of the PR and marks the comment expired', async () => {
  gh.addArtifact({ name: 'simpr-pr-42-2222222222222222.zip', workflow_run: { id: 2 } });
  await cli('cleanup', { SIMPR_PR: '42', SIMPR_MERGED: 'true' });
  assert.equal(gh.state.artifacts.filter((a) => a.name.startsWith('simpr-pr-42-')).length, 0);
  assert.ok(gh.state.artifacts.some((a) => a.name.startsWith('simpr-pr-7-')), 'other PR untouched');
  const comment = gh.state.comments.find((c) => c.issue === 42);
  assert.match(comment.body, /because this pull request was merged/);
  assert.equal(parseState(comment.body).status, 'expired');
});

test('sweep deletes orphans and marks open PRs whose build expired', async () => {
  gh.state.artifacts = [];
  gh.state.pulls.set(7, { number: 7, state: 'closed', merged_at: null, head: { sha: 'x' } });
  gh.state.pulls.set(8, { number: 8, state: 'open', head: { sha: 'x' } });
  const closedBuild = gh.addArtifact({ name: 'simpr-pr-7-1111111111111111.zip', workflow_run: { id: 1 } });
  const expired = gh.addArtifact({ name: 'simpr-pr-8-1111111111111111.zip', workflow_run: { id: 1 }, expired: true });
  const unrelated = gh.addArtifact({ name: 'test-results', workflow_run: { id: 1 } });
  gh.state.comments.push({
    id: 9999,
    issue: 8,
    body: `${COMMENT_MARKER}\n<!-- simpr:state {"status":"ready","artifactId":${expired.id}} -->`,
    user: { login: 'github-actions[bot]', type: 'Bot' },
  });

  const dry = await cli('sweep', { SIMPR_DRY_RUN: 'true' });
  assert.match(dry.stdout, /would delete simpr-pr-7/);
  assert.equal(gh.state.artifacts.length, 3, 'dry run deletes nothing');

  await cli('sweep', { SIMPR_MAX_AGE_DAYS: '30' });
  const ids = gh.state.artifacts.map((a) => a.id);
  assert.deepEqual(ids, [unrelated.id]);
  assert.ok(!ids.includes(closedBuild.id));
  assert.match(gh.state.comments.find((c) => c.id === 9999).body, /retention period[\s\S]*Re-run all jobs/);
});

test('publish-from-run refuses metadata that lies about the PR', async () => {
  gh.state.artifacts = [];
  gh.state.runs.set(900, { id: 900, conclusion: 'success', head_sha: 'f'.repeat(40) });
  gh.state.pulls.set(42, { number: 42, state: 'open', head: { sha: manifestFixture.commitSha } });
  const build = gh.addArtifact({ name: 'simpr-pr-42-0123456789abcdef.zip', workflow_run: { id: 900 } });
  const meta = { schemaVersion: 1, reused: false, manifest: manifestFixture, artifact: { id: build.id, name: build.name, runId: 900 } };
  gh.addArtifact({ name: 'simpr-meta.json', workflow_run: { id: 900 }, blob: Buffer.from(JSON.stringify(meta)) });

  await assert.rejects(cli('publish-from-run', { SIMPR_SOURCE_RUN_ID: '900' }), /Refusing to publish/);
});

test('publish-from-run comments when the run, PR head and metadata agree', async () => {
  gh.state.artifacts = [];
  gh.state.comments = [];
  gh.state.runs.set(901, { id: 901, conclusion: 'success', head_sha: manifestFixture.commitSha });
  const build = gh.addArtifact({ name: 'simpr-pr-42-0123456789abcdef.zip', workflow_run: { id: 901 } });
  const meta = { schemaVersion: 1, reused: false, manifest: manifestFixture, artifact: { id: build.id, name: build.name, runId: 901 } };
  gh.addArtifact({ name: 'simpr-meta.json', workflow_run: { id: 901 }, blob: Buffer.from(JSON.stringify(meta)) });

  await cli('publish-from-run', { SIMPR_SOURCE_RUN_ID: '901' });
  assert.equal(gh.state.comments.length, 1);
  assert.ok(!gh.state.requests.some((r) => r.path.startsWith('/blob/') && r.auth), 'token never sent to blob storage');
});

test('package and find-existing round-trip a real zip', { skip: !isMac && 'needs ditto, plutil and lipo' }, async () => {
  gh.state.artifacts = [];
  const dir = mkdtempSync(join(tmpdir(), 'simpr-pkg-'));
  const app = fakeApp(dir);
  const sha = manifestFixture.commitSha;
  const pkg = await cli('package', {
    SIMPR_APP_PATH: app,
    SIMPR_OUTPUT_DIR: join(dir, 'out'),
    SIMPR_PR: '42',
    SIMPR_SHA: sha,
    SIMPR_CONTENT_KEY: '0123456789abcdef',
    SIMPR_SCHEME: 'SampleApp',
    SIMPR_CONFIGURATION: 'Debug',
  });
  const zip = pkg.outputs['zip-path'];
  assert.match(zip, /simpr-pr-42-0123456789abcdef\.zip$/);
  assert.deepEqual(pkg.outputs.architectures.split(',').sort(), ['arm64', 'x86_64']);

  const manifest = JSON.parse(readFileSync(pkg.outputs['manifest-path'], 'utf8'));
  assert.equal(manifest.bundleId, 'dev.simpr.SampleApp');
  assert.equal(manifest.appName, 'Sample App');
  assert.equal(manifest.version, '1.2');
  assert.equal(manifest.buildNumber, '34');
  assert.equal(manifest.minimumOSVersion, '17.0');
  assert.equal(manifest.folderName, 'Sample-App-PR42-0123456');

  // The zip keeps the folder, the manifest and the executable bit.
  const x = mkdtempSync(join(tmpdir(), 'simpr-unzip-'));
  execFileSync('ditto', ['-x', '-k', zip, x]);
  assert.ok(existsSync(join(x, manifest.folderName, 'simpr.json')));
  assert.ok(statSync(join(x, manifest.folderName, 'SampleApp.app', 'SampleApp')).mode & 0o111, 'executable bit kept');

  gh.addArtifact({ name: 'simpr-pr-42-0123456789abcdef.zip', workflow_run: { id: 77 }, blob: readFileSync(zip) });
  const found = await cli('find-existing', { SIMPR_ARTIFACT_NAME: 'simpr-pr-42-0123456789abcdef.zip' });
  assert.equal(found.outputs.exists, 'true');
  assert.equal(JSON.parse(found.outputs['artifact-json']).runId, 77);
  assert.equal(JSON.parse(readFileSync(found.outputs['manifest-path'], 'utf8')).contentKey, '0123456789abcdef');

  const missing = await cli('find-existing', { SIMPR_ARTIFACT_NAME: 'simpr-pr-42-ffffffffffffffff.zip' });
  assert.equal(missing.outputs.exists, 'false');
});
