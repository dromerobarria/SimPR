import { test } from 'node:test';
import assert from 'node:assert/strict';

import { artifactName, parseArtifactName, assertPrNumber } from '../src/lib/naming.mjs';
import { validateManifest, folderNameFor } from '../src/lib/manifest.mjs';
import {
  renderReadyComment,
  renderExpiredComment,
  findStickyComment,
  parseState,
  runPageUrl,
  badgeUrl,
  terminalCommand,
  shellQuote,
  formatBytes,
  COMMENT_MARKER,
} from '../src/lib/comment.mjs';
import { selectSuperseded, selectForSweep } from '../src/lib/prune.mjs';
import { createClient } from '../src/lib/github.mjs';
import { manifest, artifact, apiArtifact } from './fixtures.mjs';

// ---------- naming ----------

test('artifact names round-trip', () => {
  const name = artifactName(42, '0123456789abcdef');
  assert.equal(name, 'simpr-pr-42-0123456789abcdef.zip');
  assert.deepEqual(parseArtifactName(name), { pr: 42, contentKey: '0123456789abcdef' });
});

test('parseArtifactName ignores other artifacts', () => {
  for (const n of ['simpr-meta.json', 'simpr-pr-42-XYZ.zip', 'simpr-pr-x-0123456789abcdef.zip', 'build.zip', null]) {
    assert.equal(parseArtifactName(n), null, String(n));
  }
});

test('PR numbers are validated', () => {
  assert.equal(assertPrNumber('7'), 7);
  for (const bad of ['0', '-1', '1.5', 'abc', '', '7; rm -rf /']) assert.throws(() => assertPrNumber(bad), bad);
  assert.throws(() => artifactName(1, 'NOT-HEX'));
});

// ---------- manifest ----------

test('valid manifest passes', () => {
  assert.equal(validateManifest({ ...manifest }).bundleId, 'dev.simpr.SampleApp');
});

test('invalid manifests list their problems', () => {
  assert.throws(() => validateManifest({ ...manifest, bundleId: 'no spaces allowed' }), /bundleId/);
  assert.throws(() => validateManifest({ ...manifest, commitSha: 'abc' }), /commitSha/);
  assert.throws(() => validateManifest({ ...manifest, architectures: ['armv7'] }), /architectures/);
  assert.throws(() => validateManifest({ ...manifest, folderName: '../x' }), /folderName/);
  assert.throws(() => validateManifest({ ...manifest, schemaVersion: 2 }), /schemaVersion/);
  assert.throws(() => validateManifest({ ...manifest, repository: 'not a repo' }), /repository/);
  assert.throws(() => validateManifest(null));
});

test('folderNameFor is shell- and filesystem-safe', () => {
  assert.equal(folderNameFor('Sample App', 42, manifest.commitSha), 'Sample-App-PR42-0123456');
  assert.equal(folderNameFor('Café $(rm)', 1, manifest.commitSha), 'Caf-rm-PR1-0123456');
  assert.equal(folderNameFor('***', 1, manifest.commitSha), 'App-PR1-0123456');
});

// ---------- comment ----------

test('runPageUrl carries the run parameters and normalizes the base', () => {
  for (const base of ['https://o.github.io/SimPR', 'https://o.github.io/SimPR/', 'https://o.github.io/SimPR/index.html?x=1']) {
    const url = new URL(runPageUrl(base, { manifest, artifact }));
    assert.equal(url.origin + url.pathname, 'https://o.github.io/SimPR/');
    assert.equal(url.searchParams.get('repo'), 'octo/sample');
    assert.equal(url.searchParams.get('pr'), '42');
    assert.equal(url.searchParams.get('sha'), manifest.commitSha);
    assert.equal(url.searchParams.get('artifact'), '1001');
    assert.equal(url.searchParams.get('run'), '555');
    assert.equal(url.searchParams.get('bundle'), 'dev.simpr.SampleApp');
    assert.equal(url.searchParams.get('arch'), 'arm64,x86_64');
    assert.equal(url.searchParams.get('app'), 'Sample App');
    assert.equal(url.searchParams.get('x'), null);
  }
  assert.equal(badgeUrl('https://o.github.io/SimPR'), 'https://o.github.io/SimPR/badge.svg');
  assert.throws(() => runPageUrl('http://evil.example', { manifest, artifact }), /https/);
});

test('shellQuote', () => {
  assert.equal(shellQuote('SampleApp.app'), 'SampleApp.app');
  assert.equal(shellQuote('My App.app'), "'My App.app'");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(shellQuote('$(whoami)'), "'$(whoami)'");
});

test('terminal command is pre-filled and quoted', () => {
  const cmd = terminalCommand({ manifest: { ...manifest, appBundleName: 'My App.app' }, artifact });
  assert.match(cmd, /gh api repos\/octo\/sample\/actions\/artifacts\/1001\/zip > "\$D\/build.zip"/);
  assert.match(cmd, /xcrun simctl install booted "\$D"\/Sample-App-PR42-0123456\/'My App.app'/);
  assert.match(cmd, /xcrun simctl launch booted dev.simpr.SampleApp$/);
  assert.match(cmd, /open -a Simulator/);
});

test('ready comment contains everything the reviewer needs', () => {
  const body = renderReadyComment({ manifest, artifact, redirectBaseUrl: 'https://o.github.io/SimPR/' });
  assert.ok(body.startsWith(COMMENT_MARKER));
  assert.match(body, /\[!\[Run in iOS Simulator\]\(https:\/\/o\.github\.io\/SimPR\/badge\.svg\)\]\(https:\/\/o\.github\.io\/SimPR\/\?/);
  assert.match(body, /\[⬇️ Download build\]\(https:\/\/github\.com\/octo\/sample\/actions\/runs\/555\/artifacts\/1001\)/);
  assert.match(body, /`0123456`/);
  assert.match(body, /2026-10-09 12:34 UTC/);
  assert.match(body, /1\.2 MB download/);
  assert.match(body, /\| Minimum iOS \| 17\.0 \|/);
  assert.match(body, /26\.6 \(17F113\)/);
  assert.match(body, /<details>[\s\S]*Drag `SampleApp\.app`[\s\S]*does \*\*not\*\* work[\s\S]*```sh[\s\S]*<\/details>/);
  assert.match(body, /Install the \[SimPR Mac app\]/);
  assert.deepEqual(parseState(body), {
    status: 'ready',
    artifactId: 1001,
    artifactName: artifact.name,
    runId: 555,
    contentKey: manifest.contentKey,
    sha: manifest.commitSha,
  });
});

test('ready comment escapes untrusted text', () => {
  const body = renderReadyComment({
    manifest: { ...manifest, appName: '<img src=x onerror=alert(1)>[link](http://evil)' },
    artifact,
    redirectBaseUrl: 'https://o.github.io/SimPR/',
  });
  assert.ok(!body.includes('<img'));
  assert.ok(!body.includes('[link](http://evil)'));
});

test('state JSON cannot close the HTML comment', () => {
  const body = renderExpiredComment({ reason: 'merged', previousState: { artifactName: 'x-->y' } });
  const stateLine = body.split('\n').at(-1);
  assert.equal(stateLine.indexOf('-->'), stateLine.length - 3);
  assert.equal(parseState(body).artifactName, 'x-->y');
});

test('expired comments explain why and how to rebuild', () => {
  assert.match(renderExpiredComment({ reason: 'merged' }), /because this pull request was merged/);
  assert.match(renderExpiredComment({ reason: 'closed' }), /because this pull request was closed/);
  const retention = renderExpiredComment({ reason: 'retention' });
  assert.match(retention, /retention period/);
  assert.match(retention, /Re-run all jobs/);
  assert.equal(parseState(retention).status, 'expired');
});

test('findStickyComment prefers the Actions bot', () => {
  const comments = [
    { id: 1, body: `${COMMENT_MARKER}\nfake`, user: { login: 'mallory', type: 'User' } },
    { id: 2, body: 'unrelated', user: { login: 'github-actions[bot]', type: 'Bot' } },
    { id: 3, body: `${COMMENT_MARKER}\nreal`, user: { login: 'github-actions[bot]', type: 'Bot' } },
  ];
  assert.equal(findStickyComment(comments).id, 3);
  assert.equal(findStickyComment(comments.slice(0, 2)), null, 'never adopts a user comment with the marker');
  assert.equal(findStickyComment(comments, { authorLogin: 'mallory' }).id, 1);
});

test('formatBytes', () => {
  assert.equal(formatBytes(999), '999 B');
  assert.equal(formatBytes(1_500), '1.5 KB');
  assert.equal(formatBytes(12_300_000), '12.3 MB');
  assert.equal(formatBytes(undefined), 'unknown');
});

// ---------- prune ----------

test('selectSuperseded keeps the current build plus keep-1 newest', () => {
  const arts = [
    apiArtifact({ id: 1, created: '2026-10-01T00:00:00Z', key: '1111111111111111' }),
    apiArtifact({ id: 2, created: '2026-10-02T00:00:00Z', key: '2222222222222222' }),
    apiArtifact({ id: 3, created: '2026-10-03T00:00:00Z', key: '3333333333333333' }),
    apiArtifact({ id: 9, pr: 7, created: '2026-10-03T00:00:00Z' }),
    { id: 10, name: 'other-artifact', created_at: '2026-10-03T00:00:00Z' },
  ];
  assert.deepEqual(selectSuperseded(arts, { pr: 42, keep: 1, currentId: 3 }).map((a) => a.id), [2, 1]);
  assert.deepEqual(selectSuperseded(arts, { pr: 42, keep: 2, currentId: 3 }).map((a) => a.id), [1]);
  // A reused older build is current: the newer one is superseded.
  assert.deepEqual(selectSuperseded(arts, { pr: 42, keep: 1, currentId: 1 }).map((a) => a.id), [3, 2]);
  assert.deepEqual(selectSuperseded(arts, { pr: 42, keep: 0, currentId: 3 }).map((a) => a.id), [2, 1], 'keep < 1 means 1');
});

test('selectSuperseded does not spend the keep budget on expired builds', () => {
  const arts = [
    apiArtifact({ id: 1, created: '2026-10-01T00:00:00Z', key: '1111111111111111' }),
    apiArtifact({ id: 2, created: '2026-10-02T00:00:00Z', key: '2222222222222222', expired: true }),
    apiArtifact({ id: 3, created: '2026-10-03T00:00:00Z', key: '3333333333333333' }),
  ];
  assert.deepEqual(selectSuperseded(arts, { pr: 42, keep: 2, currentId: 3 }).map((a) => a.id), [2]);
});

test('selectForSweep', () => {
  const now = new Date('2026-10-09T00:00:00Z');
  const arts = [
    apiArtifact({ id: 1, pr: 1, created: '2026-10-08T00:00:00Z' }), // open, fresh: keep
    apiArtifact({ id: 2, pr: 2, created: '2026-10-08T00:00:00Z' }), // merged
    apiArtifact({ id: 3, pr: 3, created: '2026-10-08T00:00:00Z' }), // PR missing
    apiArtifact({ id: 4, pr: 1, created: '2026-08-01T00:00:00Z' }), // too old
    apiArtifact({ id: 5, pr: 1, created: '2026-10-08T00:00:00Z', runId: null }), // run gone
    apiArtifact({ id: 6, pr: 1, created: '2026-10-08T00:00:00Z', expired: true }),
    { id: 7, name: 'coverage', created_at: '2020-01-01T00:00:00Z' }, // not ours
  ];
  const prStates = new Map([[1, 'open'], [2, 'merged']]);
  const result = selectForSweep(arts, { prStates, maxAgeDays: 30, now });
  assert.deepEqual(
    result.map((r) => [r.artifact.id, r.reason]),
    [[2, 'pr-merged'], [3, 'pr-missing'], [4, 'max-age'], [5, 'run-missing'], [6, 'expired']],
  );
  assert.equal(selectForSweep(arts, { prStates, maxAgeDays: 0, now }).some((r) => r.artifact.id === 4), false);
});

// ---------- client ----------

test('client paginates and sends auth headers', async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const page = Number(new URL(url).searchParams.get('page'));
    const count = page === 1 ? 100 : 3;
    const artifacts = Array.from({ length: count }, (_, i) => ({ id: page * 1000 + i }));
    return new Response(JSON.stringify({ artifacts }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const client = createClient({ token: 't0k', fetchImpl });
  const items = [];
  for await (const a of client.paginate('/repos/o/r/actions/artifacts', { key: 'artifacts' })) items.push(a);
  assert.equal(items.length, 103);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].init.headers.Authorization, 'Bearer t0k');
});

test('client surfaces API errors with status', async () => {
  const fetchImpl = async () => new Response('{"message":"nope"}', { status: 403, headers: { 'content-type': 'application/json' } });
  const client = createClient({ token: 't', fetchImpl });
  await assert.rejects(client.request('GET', '/x'), (e) => e.status === 403 && /nope/.test(e.message));
});
