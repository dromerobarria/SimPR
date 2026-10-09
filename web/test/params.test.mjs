import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseRunParams, schemeUrl, downloadUrl, terminalCommand, isMac } from '../public/params.mjs';
import { runPageUrl, terminalCommand as commentCommand } from '../../action/src/lib/comment.mjs';

const manifest = {
  repository: 'octo/sample',
  prNumber: 42,
  commitSha: '0123456789abcdef0123456789abcdef01234567',
  appName: 'Sample App',
  bundleId: 'dev.simpr.SampleApp',
  folderName: 'Sample-App-PR42-0123456',
  appBundleName: 'My App.app',
  minimumOSVersion: '17.0',
  architectures: ['arm64', 'x86_64'],
  contentKey: '0123456789abcdef',
};
const artifact = { id: 1001, runId: 555, name: 'simpr-pr-42-0123456789abcdef.zip', sizeBytes: 1234 };

const fromComment = () => new URL(runPageUrl('https://octo.github.io/SimPR/', { manifest, artifact })).searchParams;

test('accepts the exact link the action generates', () => {
  const result = parseRunParams(fromComment());
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  assert.equal(result.value.repo, 'octo/sample');
  assert.equal(result.value.app, 'Sample App');
  assert.equal(result.value.arch, 'arm64,x86_64');
});

test('page and comment build the same terminal command', () => {
  const { value } = parseRunParams(fromComment());
  assert.equal(terminalCommand(value), commentCommand({ manifest, artifact }));
});

test('rejects missing and malformed values', () => {
  const cases = {
    repo: ['octo', 'octo/sample/extra', '-octo/sample', 'octo/..', 'octo/sa mple', 'octo/sample;rm'],
    pr: ['0', '-1', '1e3', 'abc'],
    sha: ['0123456', 'G'.repeat(40)],
    artifact: ['', 'x'],
    bundle: ['com', 'com..x', 'com.x;y'],
    appfile: ['../evil.app', 'a/b.app', 'App'],
    folder: ['a/b', '..x/y', 'a b', '..', '.'],
    arch: ['armv7', 'arm64,ppc'],
    minos: ['17.0.0.1', 'x'],
    name: ['simpr-pr-99-0123456789abcdef.zip', 'other.zip'],
  };
  for (const [field, values] of Object.entries(cases)) {
    for (const bad of values) {
      const p = fromComment();
      p.set(field, bad);
      const result = parseRunParams(p);
      assert.equal(result.ok, false, `${field}=${bad} should be rejected`);
    }
  }
  const p = fromComment();
  p.delete('sha');
  assert.deepEqual(parseRunParams(p).errors, ['Missing "sha".']);
});

test('scheme URL forwards only validated fields', () => {
  const p = fromComment();
  p.set('evil', 'javascript:alert(1)');
  const { value } = parseRunParams(p);
  const url = new URL(schemeUrl(value));
  assert.equal(url.protocol, 'simpr:');
  assert.equal(url.host, 'run');
  assert.equal(url.searchParams.get('evil'), null);
  assert.equal(url.searchParams.get('artifact'), '1001');
  assert.equal(url.searchParams.get('v'), '1');
});

test('download link points at the GitHub artifact page', () => {
  const { value } = parseRunParams(fromComment());
  assert.equal(downloadUrl(value), 'https://github.com/octo/sample/actions/runs/555/artifacts/1001');
});

test('terminal command is omitted without the fields it needs', () => {
  const p = fromComment();
  p.delete('folder');
  assert.equal(terminalCommand(parseRunParams(p).value), null);
});

test('isMac', () => {
  assert.equal(isMac('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 'MacIntel', 0), true);
  assert.equal(isMac('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 'MacIntel', 5), false, 'iPad');
  assert.equal(isMac('Mozilla/5.0 (Windows NT 10.0; Win64; x64)', 'Win32', 0), false);
});
